-- lualib/config_mgr.lua
-- 配置管理库 - 提供统一的配置访问接口

local skynet = require "skynet"
local sharedata = require "skynet.sharedata"
local cjson = require "cjson"
local lfs = require "lfs"

local M = {}
local _config_cache = {}      -- 配置数据缓存
local _config_watchers = {}   -- 配置变更监听器
local _config_versions = {}   -- 配置版本信息

M._config_path = "config"

-- 递归加载所有 JSON 配置
function M.load_all_configs()
    local function load_dir(dir_path, prefix)
        for name in lfs.dir(dir_path) do
            if name ~= "." and name ~= ".." then
                local full_path = dir_path .. "/" .. name
                local attr = lfs.attributes(full_path)
                
                if attr.mode == "directory" then
                    -- 递归加载子目录
                    local new_prefix = prefix and (prefix .. "." .. name) or name
                    load_dir(full_path, new_prefix)
                elseif name:match("%.lua$") then
                    -- 加载 JSON 文件
                    M.load_single_config(full_path, prefix, name:gsub("%.lua$", ""))
                end
            end
        end
    end
    
    load_dir(M._config_path)
end

-- 加载单个配置文件
function M.load_single_config(file_path, prefix, config_name)
    print(file_path, prefix, config_name)
    -- local f = io.open(file_path, "r")
    -- if not f then
    --     skynet.error(string.format("[ConfigMgr] 配置文件不存在: %s", file_path))
    --     return false
    -- end
    
    -- local content = f:read("*a")
    -- f:close()
    
    -- local ok, data = pcall(cjson.decode, content)
    -- if not ok then
    --     skynet.error(string.format("[ConfigMgr] JSON 解析失败: %s, 错误: %s", file_path, data))
    --     return false
    -- end
    
    -- -- 构建配置键名
    -- local key
    -- if prefix then
    --     key = prefix .. "." .. config_name
    -- else
    --     key = config_name
    -- end
    
    -- -- 更新 sharedata
    -- local version = os.time()
    -- sharedata.update(key, function(old)
    --     _config_versions[key] = version
    --     return data
    -- end)
    
    -- -- 更新缓存
    -- _config_cache[key] = data
    
    -- skynet.error(string.format("[ConfigMgr] 加载配置: %s (版本: %d)", key, version))
    
    -- -- 通知监听器
    -- M.notify_watchers(key, data, version)
    
    -- return true, version
end



return M