local skynet = require "skynet"
require "skynet.manager"



skynet.start(function()
    skynet.error('account start')

    local console_port = skynet.getenv("console_port")
    if console_port then
        skynet.newservice("debug_console",console_port)
    end

    skynet.call(skynet.newservice("mysqlpool"), "lua", "open", {
		host 	= skynet.getenv("db_host"),
		port 	= skynet.getenv("db_port"),
		database 	= skynet.getenv("db_db"),
		user 		= skynet.getenv("db_user"),
		password 	= skynet.getenv("db_pwd"),
		name = ".mysql",
	})
    skynet.call(skynet.newservice("redispool"), "lua", "open", {
		host 	= skynet.getenv("redis_host"),
		port 	= skynet.getenv("redis_port"),
		db 		= skynet.getenv("redis_db"),
		auth 	= skynet.getenv("redis_auth"),
		name = ".redis",
	})


    -- 先加载配置
    require "config_helper"
    
	skynet.newservice("agent_manager")
    -- skynet.newservice("general_manager")
    skynet.newservice("map_manager")
    skynet.newservice("chat_manager")
    skynet.newservice("union_manager")



    -- 服务发现永远放在最后面
    local addr = skynet.uniqueservice("redis_discover")
	skynet.call(addr,"lua","start")

    skynet.exit()
end)