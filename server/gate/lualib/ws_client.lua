local skynet = require "skynet"
local basefunc = require "basefunc"
local base = require "base"
local websocket = require "http.websocket"
local sharetable = require "skynet.sharetable"
local error_code = require "error_code"
-- local sprotoloader = require "sprotoloader"
-- local sproto_core = require "sproto.core"
local cjson = require "cjson"
local cluster = require "skynet.cluster"
local protoid = require "protoid"
local crypt = require "mycrypt"
local CRYPT = require "lcrypt"
local time = require "time"
local gzip = require "gzip"
-- 启用空表作为数组
cjson.encode_empty_table_as_array(true)
local protoloader
local sprotoloader

local _AuthInterval = 50 -- connect 到 auth 的间隔

local notice_login_time = 3

local client = basefunc.class()
-- 本连接处理的请求
client.req = {}



local CMD = base.CMD
local PUBLIC = base.PUBLIC
local DATA = base.DATA

-- 协议解包/打包
local proto_pack, proto_unpack
-- 登录服节点
-- client 对象的 id ，在当前 gate agent 中唯一
local last_client_id = 0

function client.init()

    -- client.load_sproto()

    CMD.reload_protocol()
end
function client:pack_self()
    if not self.node then
        self.node = {
            node = skynet.getenv("cluster_type"),
            addr = skynet.self(),
            client = self.id,
            fd = self.fd,
        }
    end
    return self.node
end

function CMD.reload_protocol()
    local protocol = skynet.getenv("protocol")
    -- print("reload_protocol", protocol)
    if protocol == "json" then
        proto_pack = function(data)
            return cjson.encode(data)
        end
        proto_unpack = function(msg) return cjson.decode(msg) end
    end
    if protocol == "sproto" then
        sprotoloader = sprotoloader or require "sprotoloader"
        local host = sprotoloader.load(SPROTO_SLOT.RPC):host "package"
        local attach = host:attach(sprotoloader.load(SPROTO_SLOT.RPC))

        proto_pack = function(cmd, data, session, prefix)
            session = session or 1
            return attach(cmd, data, session)
        end
        proto_unpack = function(msg) return host:dispatch(msg) end
    end
    if protocol == "protobuf3" then
        protoloader = protoloader or require "proto/proto3/protobuf3_helper"
        local host = protoloader.new({pbfiles = sharetable.query("pbprotos")})
        proto_pack = function(cmd, data, session, prefix)
            return host:pack_message(cmd, data, session, prefix)
        end
        proto_unpack = function(msg, sz, prefix, need_unpack)
            return host:dispatch(msg, sz, prefix, need_unpack)
        end
    end
end
-- 解包协议
function CMD.unpack_message(msg, sz, prefix, need_unpack)
    return proto_unpack(msg, sz, prefix, need_unpack)
end
-- 打包协议
function CMD.pack_message(cmd, data, session, prefix)
    return proto_pack(cmd, data, session, prefix)
end

function client:ctor()

    last_client_id = last_client_id + 1
    self.id = last_client_id

end
-- 生成随机密钥
local function generate_secret_key()
    local chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local key = ""
    for i = 1, 16 do
        local idx = math.random(1, #chars)
        key = key .. string.sub(chars, idx, idx)
    end
    return key
end

-- 连接的时候调用
function client:on_connect(fd, addr)

    self.fd = fd

    self.ip = string.gsub(addr, "(:.*)", "")

    self:print_log("new client", fd, addr)

    -- 首次连接时间
    self.auth_time_out = os.time() + _AuthInterval

    self.auth = false

    self.gate_link = {
        node = skynet.getenv("cluster_type"),
        addr = skynet.self(),
        fd = self.fd,
        ip = self.ip,
        id = self.id,
    }

    -- 用于匹配发回 response 的 id
    self._last_responeId = 0

    -- 发回的 response 暂存: response id => response
    self.responses = {}

    -- 请求的名称缓存： response id => name
    self.req_names = {}

    -- 接受消息时间记录： response id => time
    self.req_time = {}

    -- 玩家 agent 的 service id
    self.player_agent_id = nil

    -- 玩家agent 连接
    self.agent_link = nil

    -- 登录 id，登录成功后有效
    self.login_id = nil

    -- 上次发送login消息时间
    self.login_time = nil

    -- 用户 id，登录成功后有效
    self.pid = nil

    -- 消息序号
    self._request_number = 0

    -- 在此时间后才处理此玩家消息
    self._forbid_request_time = nil

    -- 连接已断开
    self._dis_connected = false

    -- 已经禁止收数据
    self._forbid_request = false

    -- 消息限制计数器
    self.__limit_request_counter = 0

    -- 等待踢出
    self._wait_kick = false

    -- 通讯密码
    self.proto_key = nil

    -- 心跳时间
    self.heartbeat_time = os.time()

    -- 是否已握手   已握手后需要将每条消息加解密
    self.handshake = false
    -- 发送通信密钥（握手消息）
    local secret_key = generate_secret_key()
    self.proto_key = secret_key
    -- rlog("生成密钥", self.id, "密钥长度", #secret_key, "密钥", secret_key)
    
    skynet.timeout(20, function()
        -- 立即发送握手消息，不延迟
        -- 握手消息：不加密，只压缩
        -- local handshake_msg = cjson.encode({ code = error_code.success, seq = 0, name = protoid.handshake, msg = { key = secret_key}})
        -- local comp = gzip.deflate(handshake_msg)
        -- websocket.write(self.fd, comp, "binary")
        self:send2client(
            {
                name = protoid.handshake, 
                msg = {key = secret_key}, 
                code = error_code.success, 
                seq = MSG_TYPE.S2C,
            })
        self.handshake = true
        -- rlog("发送握手消息", self.id, "secretKey长度", #secret_key)
    end)

end
-- 断开的时候调用
function client:on_disconnect()
    self._dis_connected = true
    if self.game_link then
        CMD.cluster_send(self.game_link.node, ".agent_manager", "disconnect", self.rid)
    end

end

-- 游戏服创建好了agent
function client:update_game_link(game_link, rid)

    self.game_link = game_link
    self.rid = rid
    rlog("更新玩家agent和所选角色rid", rid)
end
-- 登录结果
function client:update_login_state(user, state)

    self.login_state = state
    self.user = user
    rlog("更新玩家登录状态", user.username, user.uid, state)
end

function client:send_package(pack)

    if string.len(pack) <= 0 then return end

    if self.fd then
        -- 根据加密文档：序列化 -> 加密（如果已握手）-> 压缩 -> 发送
        dlog("发送消息",self.id, pack)
        -- 1. 加密（如果已握手且不是握手消息）
        if self.proto_key and string.len(pack) > 0 and self.handshake then
            
            local encrypted, err = crypt.aes_128_cbc_encrypt(
                self.proto_key,
                pack,
                self.proto_key,
                true,  -- hex
                0      -- padding
            )
            if encrypted then
                pack = encrypted
            else
                elog("AES加密失败", err)
                return
            end
        end

        -- 2. 压缩
        local compressed = gzip.deflate(pack)
        if not compressed then
            elog("Gzip压缩失败")
            return
        end
        
        -- 3. 发送
        websocket.write(self.fd, compressed, "binary")
    end
end

function client:print_log(_info, ...)
    rlog(string.format("[cli-%d#%d]", self.id or 0, self.fd or 0) ..
              tostring(_info), ...)
end

function client:gen_response_id(_req_name, _resp)

    print("self._last_responeId", self._last_responeId, self.id)
    assert(self._last_responeId)
    self._last_responeId = self._last_responeId + 1
    local _responeId = self._last_responeId

    self.responses[_responeId] = _resp
    self.req_names[_responeId] = _req_name
    self.req_time[_responeId] = skynet.now()

    return _responeId
end

function client:del_response_id(_response_id)
    if _response_id then
        self.responses[_response_id] = nil
        self.req_names[_response_id] = nil
        self.req_time[_response_id] = nil
    end
end

function client:check_responses()

    -- 移除过期的

    local _remove
    local _now = skynet.now()
    local _timeout_cfg = 2000 -- 单位： 0.01 秒
    for k, v in pairs(self.req_time) do
        if _now - v > _timeout_cfg then
            _remove = _remove or {}
            table.insert(_remove, k)
        end
    end

    if _remove then
        for _, v in ipairs(_remove) do self:del_response_id(v) end
    end
end

-- 记录消息日志
-- 参数 _type ： 类型：  "request_c2s" , "request_s2c", "response_s2c"
function client:log_msg(_type, _name, _data, responeId)
    print("log_msg", _type, _name, _data, responeId)
    local _t_diff = -1
    if self.req_time[responeId] then
        _t_diff = skynet.now() - self.req_time[responeId]
        if _t_diff > 300 then
            elog("message reponse time too long:",
                     string.format("type=%s, msg='%s',t=%s,response id=%s:",
                                   _type, _name, _t_diff, responeId or 0) ..
                         cjson.encode(_data))
        end
    end

    -- -- 心跳需要主动配置（因为太频繁）
    -- if _name == "heartbeat" then
    --     return
    -- end

    -- if not skynet.getenv("network_error_debug") then
    -- 	return
    -- end

    -- if not skynet.getenv("log_all_msg") then
    --     local _no_log = nodefunc.get_global_config("debug_no_log")
    --     if _no_log and _no_log[_name] then
    --         return
    --     end
    -- end

    self:print_log(string.format("[gate msg] %s '%s' t(%s) #%s:", _type, _name,
                                 _t_diff, responeId or 0) .. cjson.encode(_data))
end

--[[
发送消息响应包
默认 会 清除 response id 信息（除非强制 设置 _not_del_id=true）
--]]
function client:send2client(data)

    local msg = CMD.pack_message(data)
    self:send_package(msg)
end

function client:response2client(cmd, _data, resp_id)
    -- if ProtoIDs[cmd].response_id then
    --     self:send2client(ProtoIDs[cmd].response_id, _data, resp_id)
    -- else
        elog("消息没有设置回包ID",cmd)
    -- end
end

function client:send_error_code(erro_code)
    assert(erro_code)
    self:send2client("error_code", {result = erro_code})
end

-- 重新发送握手消息（当解密失败时）
function client:resend_handshake()
    if not self.fd then return end
    
    -- 重新生成密钥
    local secret_key = generate_secret_key()
    self.proto_key = secret_key
    
    -- 发送握手消息（不加密，只压缩）
    local msg = cjson.encode({ code = 0, seq = 0, name = "handshake", msg = { key = secret_key}})
    local comp = gzip.deflate(msg)
    websocket.write(self.fd, comp, "binary")
    rlog("重新发送握手消息", self.id)
end

local function binary_to_int8_array(binary_str)
    local result = {}
    for i = 1, #binary_str do
        local byte = binary_str:byte(i)
        -- 转换为有符号int8
        local int8 = byte > 127 and byte - 256 or byte
        table.insert(result, int8)
    end
    for i, value in ipairs(result) do
        local byte = binary_str:byte(i)
        print(string.format("位置 %d: 0x%02X -> int8: %d", i, byte, value))
    end
end

-- 来自客户端的请求
function client:on_request(msg, sz)
    -- msg = string.unpack(">s2", msg)
    sz = #msg
    -- binary_to_int8_array(msg)
    
    -- print("on_request self._last_responeId",  self._last_responeId, self.id)
    if self._forbid_request_time and self._forbid_request_time > 0 then
        if self._forbid_request_time < os.time() then return end
        self._forbid_request_time = nil
    end
    
    -- 根据加密文档：接收 -> 解压 -> 解密（如果已握手）-> 反序列化
    
    -- 1. 解压
    local ok,decompressed, err = pcall(gzip.inflate, msg)
    if not ok then
        elog("Gzip解压失败", decompressed or "unknown error")
        return
    end
    msg = decompressed
    sz = #msg
    
    -- 2. 解密（如果已握手）
    -- 注意：客户端发送的消息应该都是加密的（如果已握手）
    -- 握手消息是服务器发送给客户端的，客户端不会发送握手消息
    -- 客户端加密后返回的是十六进制字符串（encrypted.ciphertext.toString()）
    if self.proto_key and sz > 0 and self.handshake then
        ----------------------------------------
        --测试1
        local decrypted, err = crypt.aes_128_cbc_decrypt(
            self.proto_key,
            msg,
            self.proto_key,
            true,  -- hex
            0      -- padding
        )
        if decrypted then
            msg = decrypted
            sz = #msg
        else
            elog("AES解密失败", err, self.proto_key, msg)
        end
        
    elseif self.proto_key and sz > 0 and not self.handshake then
        -- 如果还没有握手，但收到了加密消息，可能是时序问题
        elog("收到加密消息但尚未握手", "client_id", self.id)
        return
    end
    -- 如果是sproto，返回结果应该是ok,type,name,args,response
    -- 如果是proto3，返回结果应该是ok,nil,name,args,session
    local ok, data = pcall(CMD.unpack_message, msg, sz)
    local _resp_id

    if sproto then _resp_id = self:gen_response_id(name, response) end

    if not ok then
        self._forbid_request = true
        self._wait_kick = true
        elog("协议错误",err_code, self.pid)
        return
    end
    if data.name == protoid.heartbeat then
        print("收到心跳消息", data.msg.ctime, time.gettime())
        local now = math.floor(time.gettime() / 10)
        self.heartbeat_time = os.time()
        self:send2client(
            {
                name = protoid.heartbeat, 
                msg = {ctime = data.msg.ctime, stime = now}, 
                code = error_code.success, 
                seq = data.seq
            })
        return
    end
    -- if not protoid[data.name] then
    --     elog("协议不存在",data.name)
    --     return
    -- end
    data.ip = self.ip

    self:dispatch_request(data.name, data)
    -- if not self.login then
    --     -- 没有登录直接发到登录服
    --     CMD.cluster_send(node,addr,"dispatch_request",data,self:pack_self())
    --     return
    -- end
    -- if not self.game_link then
    --     -- 已登录但没有进入到游戏
    --     CMD.cluster_send(node,addr,"dispatch_request",data,self:pack_self())
    --     return
    -- end
    -- if err_code ~= error_code.success then
    --     elog("协议解析错误",err_code, self.pid)
    --     self._forbid_request = true
    --     self._wait_kick = true
    --     return
    -- end

    if self._forbid_request then
        -- self:response2client(name, {result = error_code.forbid_network}, _resp_id)
        self._wait_kick = true
        rlog("禁止请求协议",self.id, self.pid)
        return
    end
    -- if tp == "RESPONSE" then
    --     self:send_error_code(10012)
    --     self._forbid_request = true
    --     self._wait_kick = true
    --     elog("不支持服务器下发消息的回包")
    --     return
    -- end
    -- if data.name ~= protoid.heartbeat then
    	dlog("收到消息", msg)
    -- end

    -- if self.auth == false then

    --     self.auth = true

    --     if name ~= "c2s_login" then
    --         elog("第一条消息必须是c2s_login",self.id)
    --         self._forbid_request = true
    --         self._wait_kick = true
    --         return
    --     end

    --     if not args.token then
    --         self:response2client(name, {result = error_code.token_invalid}, _resp_id)
    --         return
    --     end

    --     local err_code,data, roles = skynet.call("token_manager","lua","check_token",args.token,self.gate_link)
    --     if err_code ~= error_code.success then
    --         elog("token验证失败",err_code, self.pid)
    --         self:response2client(name, {result = err_code}, _resp_id)
    --         self._forbid_request = true
    --         self._wait_kick = true
    --         return
    --     end
    --     self.pid = data.pid
    --     self.game_link = data.game_link
    --     self.auth_time_out = nil
    --     self:response2client(name, {result = error_code.success, roles = roles}, _resp_id)
    --     return
    -- end

    -- if self.game_link then
    --     local ok, result = xpcall(client.dispatch_request,
    --                               basefunc.error_handle, self, name, args,
    --                               _resp_id)
    --     if not ok then
    --         self:print_log("call dispatch_request error:", result)
    --     end
        
    -- end


end

function PUBLIC.get_remaining_time(remaining_count)
    local remaining_time = math.abs(math.ceil(remaining_count / 10)) -- 向上取整  10 = login_manager.lua中的 max_accept_login * 2
    return remaining_time, remaining_count
end

-- 更新函数（1 秒）
function client:update(dt)

    if self._wait_kick then
        self:print_log("client kick", self.id)
        -- skynet.send(DATA.gate,"lua","kick",self.fd)
        self._wait_kick = false
        CMD.kick_client(self.id, true)
        return
    end

    -- if self.login_id and self.login_time and (os.time() - self.login_time) >
    --     notice_login_time then
    --     print("正在排队", self.id, DATA.login_deal_index,
    --           DATA.login_deal_index < self.login_id)
    --     if DATA.login_deal_index and DATA.login_deal_index < self.login_id then
    --         self:send2client("login_queue", {
    --             remaining_count = PUBLIC.get_remaining_time(
    --                 self.login_id - DATA.login_deal_index),
    --             remaining_time = 10004
    --         })
    --     end
    -- end
    -- 每 5 秒 update
    if os.time() - (self.__last_update5 or 0) >= 5 then
        self.__last_update5 = os.time()
        self:update5(dt)
    end

    self:check_login_timeout()

    if (os.time() - self.heartbeat_time) >= HEARTBEAT_TIMEOUT then
        rlog("长时间未心跳，踢人",self.id, (os.time() - self.heartbeat_time), HEARTBEAT_TIMEOUT)
        self._wait_kick = true
    end
end

-- 更新函数（5 秒）
function client:update5(dt)

    self.__limit_request_counter = 0
    self:check_responses()

end

-- 登录N秒后没有消息，直接踢
function client:check_login_timeout()
    -- 进入登录排队的除外
    -- if self.auth_time_out and os.time() >
    --     self.auth_time_out then
    --     self._forbid_request = true
    --     rlog("长时间未登录，踢人",self.id)
    --     self._wait_kick = true
    -- end

end
--[[
发送消息响应包
默认 会 清除 response id 信息（除非强制 设置 _not_del_id=true）
--]]
function client:send_response(_resp_id, _data, _not_del_id)
    local _resp = self.responses[_resp_id]
    print("服务器回包", _resp_id, _data, _not_del_id, _resp)
    if _resp then

        self:log_msg("response_s2c", tostring(self.req_names[_resp_id]), _data,
                     _resp_id)
        if _data then self:send_package(_resp(_data)) end
    end

    if not _not_del_id then self:del_response_id(_resp_id) end
end

-- 客户端消息分发
function client:dispatch_request(name, data, _resp_id)

    if self._forbid_request or self._dis_connected then return end

    self._request_number = self._request_number + 1

    -- 客户端发送请求太频繁，则断开
    self.__limit_request_counter = (self.__limit_request_counter or 0) + 1
    if self.__limit_request_counter >= DATA.max_request_rate then

        elog(string.format(
                           "error:request too much , max is %d ,but %d!",
                           DATA.max_request_rate, self.__limit_request_counter))
        -- self:response2client(name, {result = error_code.msg_times_limit}, _resp_id)
        self._wait_kick = true
        self._forbid_request = true
        return
    end

    local _func = client.req[name]

    local ok, continue_transmit = true, true
    if _func then
        ok, continue_transmit = pcall(_func, self, data)
        if not ok then
            elog("网关预处理报错", continue_transmit)
        end
    end
    if continue_transmit then
        if not self.login_state then
            -- 没登录，发到登录服
            CMD.cluster_send_by_type("login", ".login_manager", "client_request", data , self:pack_self())
            return
        end
        if self.game_link then
            if self.game_link.addr then
                CMD.cluster_send(self.game_link.node, self.game_link.addr, "client_request", data , self:pack_self())
                return
            end
        end
        CMD.cluster_send_by_type("game", ".agent_manager", "client_request", data, self:pack_self())
    end

end

----------------------网关预处理------------------------------------------
-- 返回true时消息继续转发到agent

function client.req:heartbeat(data) 
     -- print("收到心跳消息", data.msg.ctime, time.gettime())
     local now = math.floor(time.gettime() / 10)
     self.heartbeat_time = os.time()
     self:send2client(
         {
             name = protoid.heartbeat, 
             msg = {ctime = data.msg.ctime, stime = now}, 
             code = error_code.success, 
             seq = data.seq
         })
end

return client
