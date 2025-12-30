
local sharedata = require "skynet.sharedata"
local lfs = require "lfs"
local cjson = require "cjson"
local sp = {}


sp["config/general/general.lua"] = function(content)
    local list = content.list
    content.cfgIdMap = {}
    for _, v in ipairs(list) do
        content.cfgIdMap[v.cfgId] = v
    end
end



-- 递归加载所有 JSON 配置
local function load_all_configs()
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
                    -- 加载 lua 文件
					print(full_path,"加载配置文件")
					local f = io.open(full_path, "r")
					local content = f:read("*a")
    				f:close()
					content = load(content,"chunk")()
                    if sp[full_path] then
                        sp[full_path](content)
                    end
					sharedata.new(full_path, content)
                elseif name:match("%.json$") then
                    -- 加载 JSON 文件
					print(full_path,"加载配置文件")
					local f = io.open(full_path, "r")
					local content = f:read("*a")
    				f:close()
					content = cjson.decode(content)
                    if sp[full_path] then
                        sp[full_path](content)
                    end
					sharedata.new(full_path, content)
                end
            end
        end
    end
    load_dir("config")
end

load_all_configs()