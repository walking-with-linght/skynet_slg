local skynet = require "skynet"
require "skynet.manager"

skynet.start(function()
    skynet.error('gate start')

    local console_port = skynet.getenv("console_port")
    if console_port then
        skynet.newservice("debug_console",console_port)
    end

    local socket_type = skynet.getenv("socket_type") or "ws"
	local addr = nil
	if socket_type == "tcp" then
		addr = skynet.newservice("tcp")
	end
	if socket_type == "ws" then
		addr = skynet.newservice("ws")
	end
	skynet.call(addr,"lua","start",{
		port = tonumber(skynet.getenv("port")),
		maxclient = tonumber(skynet.getenv("maxclient")) or 5000,
		nodelay = true,
		protocol = skynet.getenv("use_ssl") == "true" and "wss" or "ws",
		instance = 10,--ws_agent数量
	})


    -- 服务发现永远放在最后面
    local addr = skynet.uniqueservice("redis_discover")
	skynet.call(addr,"lua","start")

	-- local crypt = require "mycrypt"
	-- for k, v in pairs(crypt) do
	-- 	print(k, v,type(v))
	-- end
    -- skynet.exit()
end)