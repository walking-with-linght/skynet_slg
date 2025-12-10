include "config.common"

start = "login_main"	-- main script

-- 节点信息
cluster_type = "login"
cluster_name = "login"
cluster_addr = "127.0.0.1:29210"

-- 开启debug
console_port = 29211
slgwebport = 8088

luaservice = luaservice .. "./server/" .. cluster_type .. "/?.lua;"
lua_path =  lua_path .. "./server/" .. cluster_type .. "/lualib/?.lua;"
