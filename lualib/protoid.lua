
return {
    -- 握手
    handshake = {
        cmd = "handshake",
        node = "gate"
    },
    -- 心跳
    heartbeat = {
        cmd = "heartbeat",
        node = "gate"
    },
    -- 登录
    ["account.login"] = {
        cmd = "account.login",
        node = "login",
        addr = ".login_manager"
    },
    -- 进入游戏
    ["role.enterServer"] = {
        cmd = "role.enterServer",
        node = "game",
        addr = ".game_manager"
    },
    -- 创建角色
    ["role.create"] = {
        cmd = "role.create",
        node = "login",
        addr = ".login_manager"
    },
}