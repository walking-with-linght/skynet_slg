local skynet = require "skynet"
local crypt = require "mycrypt"
local M = {}
local const_key = "1234567890123456"
local validTime = 30 * 24 * 3600

function M.generate_session(uid)
    local now = os.time()
    local ok, encrypted, err = pcall(crypt.aes_128_cbc_encrypt,
        const_key,
        now .. "|" .. uid,
        const_key,
        true,  -- hex
        0      -- padding
    )
    if not ok then
        print("session encrypt error", err)
        return 1, "生成session失败"
    end
    return 0,encrypted
end

function M.check_session(session)
    local ok,decrypted, err = pcall(crypt.aes_128_cbc_decrypt,
        const_key,
        session,
        const_key,
        true,  -- hex
        0      -- padding
    )
    if not ok then
        print("session decrypt error", err)
        return 1, "无效的session"
    end
    local d = string.split(decrypted, "|")
    if #d ~= 2 then
        print("session format error", decrypted)
        return 2, "无效的session"
    end
    local time,uid = d[1], d[2]
    if tonumber(time) < os.time() - validTime then
        print("session expired", time, os.time())
        return 3, "session已过期"
    end
    return 0, tonumber(uid)
end
return M