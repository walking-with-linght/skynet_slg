
local cluster = require "skynet.cluster"
local openssl = require "openssl"

 --[[
  线性同余加密id
  要求b，m互质，返回区间为[0,c)
]]
local function encode(id, a, b, m)
    return (a * id + b) % m;
end

local _M = {}


function _M.RespSuccess(data)
    return {isori="true",returnbody=data}
end

function _M.RespFail(data)
    return {isori="false"}
end

function _M.encodeUserId(id)
    if id < 100000 then
        return id
    elseif id < 1000000 then
        return encode(id, 15601, 199999, 900000) + 100000;
    elseif id < 10000000 then
        return encode(id, 156001, 1999993, 9000000) + 1000000;
    else
        return encode(id, 1560001, 1999993, 90000000) + 10000000;
    end
end

function _M.getHead(head)
    if head == nil or string.len(head) < 4 then
        return ''
    end
    local headstart = string.sub(head,0,4)
    if headstart == 'http' then
        return head
    else
        return cluster.call("master", ".configmgr", "getVal", "userFaceUrl") .. head
    end
end

function _M.random_string(length)
    local charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local result = {}
    for i = 1, length do
        local rand = math.random(1, #charset)
        result[i] = charset:sub(rand, rand)
    end
    return table.concat(result)
end

function _M.sha256(str)
    local d = openssl.digest.new("sha256")
    d:update(str)
    local bin = d:final()
    return bin
end

function _M.uuid_v4()
    local random = math.random
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'

    local uuid = template:gsub('[xy]', function (c)
        local v = (c == 'x') and random(0, 15) or random(8, 11)
        return string.format('%x', v)
    end)
    return uuid
end

--返回ISO 8601 标准的年 周
function _M.get_week()
    return os.date("%G%V")
end

function _M.read_file(filename,mode)
    local file = io.open(filename, mode)  -- 打开文件（只读模式）
    if file then
        local content = file:read("*a")        -- 读取所有内容
        file:close()                          -- 关闭文件
        return content
    end
end

--检测是否是手机号
function _M.is_phone_str(phone)
    if not phone then return nil end  -- 非字符串直接返回nil
    
    -- 1. 去除所有空白字符（包括中间的空格）
    local cleaned_phone = tostring(phone):gsub("%s+", "")
    
    -- 2. 验证手机号格式：
    --    - 1开头
    --    - 第二位3-9
    --    - 总长度11位
    --    - 纯数字
    if cleaned_phone:match("^1[3-9]%d%d%d%d%d%d%d%d%d$") then
        -- print("cleaned_phone",cleaned_phone)
        return cleaned_phone  -- 返回处理后的手机号
    else
        return nil  -- 无效手机号
    end
end
table.merge = function(dest, src)
    for k, v in pairs(src) do
        dest[k] = v
    end
end

function array_to_get_params(array)
    local params = {}
    for key, value in pairs(array) do
        table.insert(params, key .. "=" .. value)
    end
    return table.concat(params, "&")
end

table.redis_pack = function(data)
    local rs = {}
    if data ~= nil then
        for k, v in pairs(data) do
            if k % 2 == 1 then
                rs[v] = data[k + 1]
            end
        end
    end
    return rs
end
table.redis_unpack = function (data)
    local rs = {}
    if data ~= nil then
        for k, v in pairs(data) do
            table.insert(rs, k)
            table.insert(rs, v)
        end
    end
    return table.unpack(rs)
end

table.count = function (t,value)
    local count = 0
    for _,v in pairs(t) do
        if value then
            if v == value then
                count = count + 1
            end
        else
            count = count + 1
        end
    end
    return count
end

table.toarray = function (t)
    local array = {}
    for k, v in pairs(t) do
        table.insert(array, v)
    end
    return array
end

-- 获取utc0时间戳
function _M.get_utc_0_time()
    return os.time(os.date("!*t"))
end

--是否以指定字符串结尾
function _M.endsWith(str, suffix)
    return suffix == "" or string.sub(str, -#suffix) == suffix
end

function _M.iso8601_to_timestamp(iso_string)
    -- 解析 ISO 8601 格式的时间字符串
    local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+).(%d+)Z"
    local year, month, day, hour, min, sec, millis = iso_string:match(pattern)
    
    if not year then
        return nil, "Invalid ISO 8601 format"
    end
    
    -- 转换为数字类型
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, min, sec = tonumber(hour), tonumber(min), tonumber(sec)
    millis = tonumber(millis)
    
    -- 创建时间表（注意：月份范围是1-12，与os.time兼容）
    local time_table = {
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = min,
        sec = sec,
        isdst = false  -- 不使用夏令时
    }
    
    -- 转换为时间戳（UTC时间）
    local timestamp = os.time(time_table)
    
    if not timestamp then
        return nil, "Failed to convert to timestamp"
    end
    
    -- 添加毫秒部分
    local timestamp_with_millis = timestamp + millis / 1000.0
    
    return timestamp_with_millis
end

function _M.iso8601_to_local_timestamp(iso_string)
    -- 先转换为UTC时间戳
    local utc_timestamp, err = _M.iso8601_to_timestamp(iso_string)
    if not utc_timestamp then
        return nil, err
    end
    
    -- 获取本地时区与UTC的偏移量（秒）
    local now_utc = os.time(os.date("!*t"))
    local now_local = os.time(os.date("*t"))
    local timezone_offset = now_local - now_utc
    
    -- 转换为本地时区时间戳
    local local_timestamp = utc_timestamp + timezone_offset
    
    return local_timestamp
end

-- string--------
local string_gsub   = string.gsub
local table_insert  = table.insert

function string.trim(s, char)
    if io.empty(char) then
        return (string_gsub(s, "^%s*(.-)%s*$", "%1"))
    end
    return (string_gsub(s, "^".. char .."*(.-)".. char .."*$", "%1"))
end

-- 是否跨天
function _M.isCrossDay(givenTimeStr)
    -- 检查输入是否为空
    if not givenTimeStr or givenTimeStr == "" then
        return true -- 默认跨天
    end
    
    -- 获取当前时间
    local currentTime = os.time()
    local currentDate = os.date("*t", currentTime)
    
    -- 解析给定的时间字符串
    local year, month, day, hour, min, sec = string.match(givenTimeStr, 
        "(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
    
    if not year then
        -- 如果解析失败，尝试其他格式或返回false
        return false
    end
    
    -- 将字符串转换为数字
    year, month, day, hour, min, sec = 
        tonumber(year), tonumber(month), tonumber(day), 
        tonumber(hour), tonumber(min), tonumber(sec)
    
    -- 创建给定时间的时间表
    local givenTimeTable = {
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = min,
        sec = sec
    }
    
    -- 将给定时间转换为时间戳
    local givenTimestamp = os.time(givenTimeTable)
    if not givenTimestamp then
        return false
    end
    
    -- 获取给定时间的日期部分
    local givenDate = os.date("*t", givenTimestamp)
    
    -- 判断是否跨天：比较年、月、日是否都相同
    if currentDate.year == givenDate.year and
       currentDate.month == givenDate.month and
       currentDate.day == givenDate.day then
        return false  -- 同一天
    else
        return true   -- 跨天了
    end
end

-- 日期转换为时间戳
function _M.date2timestamp(givenTimeStr)
    -- 检查输入是否为空
    if not givenTimeStr or givenTimeStr == "" then
        return 0 -- 默认跨天
    end
    
    -- 获取当前时间
    local currentTime = os.time()
    local currentDate = os.date("*t", currentTime)
    
    -- 解析给定的时间字符串
    local year, month, day, hour, min, sec = string.match(givenTimeStr, 
        "(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
    
    if not year then
        -- 如果解析失败，尝试其他格式或返回false
        return 0
    end
    
    -- 将字符串转换为数字
    year, month, day, hour, min, sec = 
        tonumber(year), tonumber(month), tonumber(day), 
        tonumber(hour), tonumber(min), tonumber(sec)
    
    -- 创建给定时间的时间表
    local givenTimeTable = {
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = min,
        sec = sec
    }
    
    -- 将给定时间转换为时间戳
    return os.time(givenTimeTable)
end


return _M