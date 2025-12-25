
-- 军队
local skynet = require "skynet"
local base = require "base"
local event = require "event"
local protoid = require "protoid"
local error_code = require "error_code"
local sharedata = require "skynet.sharedata"
local cjson = require "cjson"
-- 启用空表作为数组
cjson.encode_empty_table_as_array(true)


local DATA = base.DATA --本服务使用的表
local CMD = base.CMD  --供其他服务调用的接口
local PUBLIC = base.PUBLIC --本服务调用的接口
local REQUEST = base.REQUEST

local NM = "skill"

local lf = base.LocalFunc(NM)

local all_skills = {
	path = {
		"config/skill/beidong/baizhanjingbing.lua",
		"config/skill/zhihui/fengshi.lua",
		"config/skill/zhudong/tuji.lua",
		"config/skill/zuiji/zhongzhan.lua",
	},
	map = {},
}

function lf.load(self)
	self.skills = {}
	for _, path in ipairs(all_skills.path) do
		local config = sharedata.query(path)
		all_skills.map[config.cfgId] = config
	end
	local ok,skills  = skynet.call(".mysql", "lua", "select_by_conditions", "tb_skill_1", {rid = self.rid})
	if ok and skills and #skills > 0 then
		-- print("load skills from mysql",dump(skills))
		for _, skill in pairs(skills) do
			skill.belong_generals = cjson.decode(skill.belong_generals)
			self.skills[skill.cfgId] = skill
		end
	else
		-- 需要初始化
		local idx = 0
		local insert_skills = {}
		for cfgId, skill in pairs(all_skills.map) do
			local skill ={
				rid = self.rid,
				cfgId = skill.cfgId,
				belong_generals = cjson.encode({}),
				ctime = os.date("%Y-%m-%d %H:%M:%S"),
			}
			table.insert(insert_skills, skill)
		end
		-- 保存到mysql
		local ret,result = skynet.call(".mysql", "lua", "insertAll", "tb_skill_1", insert_skills)
		for i, skill in ipairs(insert_skills) do
			skill.belong_generals = {}
			skill.id = result.insert_id + i - 1  -- 为什么-1 ？因为i从1开始的
			self.skills[skill.cfgId] = skill
		end
	end
	
end
function lf.loaded(self)

end
function lf.enter(self, seq)

end
function lf.leave(self)

end

skynet.init(function () 
	event:register("load",lf.load)
	event:register("loaded",lf.loaded)
	event:register("enter",lf.enter)
	event:register("leave",lf.leave)
end)


-- 技能列表
REQUEST[protoid.skill_list] = function(self,args)
	local list = {}
	for _, skill in pairs(self.skills) do
		list[#list + 1] = {
			id = skill.id,
			cfgId = skill.cfgId,
			generals = skill.belong_generals,
		}
	end
	CMD.send2client({
		seq = args.seq,
		msg = {
			list = list,
		},
		name = protoid.skill_list,
		code = error_code.success,
	})
end

-- 卸下技能
REQUEST[protoid.general_downSkill] = function(self,msg)
	local skill = self.skills[msg.msg.cfgId]
	if not skill then
		return CMD.send2client({
			seq = msg.seq,
			msg = {
			},
			name = protoid.general_downSkill,
			code = error_code.DownSkillError,
		})
	end
	-- 该技能没有装备该武将
	if not table.contains(skill.belong_generals, msg.msg.gId) then
		print("该技能没有装备该武将")
		return CMD.send2client({
			seq = msg.seq,
			msg = {
			},
			name = protoid.general_downSkill,
			code = error_code.DownSkillError,
		})
	end
	local skill_config = all_skills.map[msg.msg.cfgId]
	local target_general = PUBLIC.getGeneralById(self, msg.msg.gId)
	-- 或者说，只要该位置有技能，就直接卸下 可以将 msg.cfgId 改成 0 ，错误码改成 PosNotSkill
	if target_general.skills[msg.msg.pos + 1].cfgId ~= msg.msg.cfgId then
		return CMD.send2client({
			seq = msg.seq,
			msg = {
			},
			name = protoid.general_downSkill,
			code = error_code.DownSkillError,
		})
	end

	-- 卸下技能
	target_general.skills[msg.msg.pos + 1].id = 0
	target_general.skills[msg.msg.pos + 1].cfgId = 0
	target_general.skills[msg.msg.pos + 1].lv = 0
	for i, v in ipairs(skill.belong_generals) do
		if v == msg.msg.gId then
			table.remove(skill.belong_generals, i)
			break
		end
	end
	CMD.send2client({
		seq = msg.seq,
		msg = {
			cfgId = msg.msg.cfgId,
			pos = msg.msg.pos,
			gId = msg.msg.gId,
		},
		name = protoid.general_downSkill,
		code = error_code.success,
	})
	PUBLIC.saveGeneral(self, msg.msg.gId)
	PUBLIC.pushGeneral(self,msg.msg.gId)
end
-- 装备技能
REQUEST[protoid.general_upSkill] = function(self,msg)
	local cfgId = msg.msg.cfgId
	local skill = self.skills[cfgId]
	if not skill then
		print("没有找到该技能",dump(msg))
		return CMD.send2client({
			seq = msg.seq,
			name = protoid.general_upSkill,
			code = error_code.UpSkillError,
		})
	end
	-- 该技能已经装备该武将了
	if table.contains(skill.belong_generals, msg.msg.gId) then
		print("该技能已经装备该武将了")
		return CMD.send2client({
			seq = msg.seq,
			msg = {
			},
			name = protoid.general_upSkill,
			code = error_code.SkillAlreadyEquipped,
		})
	end
	local skill_config = all_skills.map[cfgId]
	-- 一个技能最多装备三个武将
	if #skill.belong_generals >= skill_config.limit then
		print("一个技能最多装备三个武将")
		return CMD.send2client({
			seq = msg.seq,
			msg = {
			},
			name = protoid.general_upSkill,
			code = error_code.SkillLevelFull,
		})
	end
	-- 一个武将最多装备三个技能
	local target_general = PUBLIC.getGeneralById(self, msg.msg.gId)
	if not target_general then
		print("没有找到该武将")
		return CMD.send2client({
			seq = msg.seq,
			msg = {
			},
			name = protoid.general_upSkill,
			code = error_code.GeneralNotFound,
		})
	end
	-- 默认会给三个初始位置，如果后续要加，这里应该有问题 todo，general_manager.lua 104行需要修改
	if not target_general.skills[msg.msg.pos + 1] then
		print("一个武将最多装备三个技能")
		return CMD.send2client({
			seq = msg.seq,
			msg = {
			},
			name = protoid.general_upSkill,
			code = error_code.PosNotSkill,
		})
	end
	for _, _skill in pairs(target_general.skills) do
		if _skill.cfgId == cfgId then
			print("该技能已经装备该武将了")
			return CMD.send2client({
				seq = msg.seq,
				msg = {
				},
				name = protoid.general_upSkill,
				code = error_code.UpSkillError,
			})
		end
	end
	
	-- 兵种是否相符
	if not table.contains(skill_config.arms, target_general.arms) then
		print("兵种不符",dump(skill_config.arms),target_general.arms)
		return CMD.send2client({
			seq = msg.seq,
			msg = {
			},
			name = protoid.general_upSkill,
			code = error_code.OutArmNotMatch,
		})
	end
	target_general.skills[msg.msg.pos + 1].id = skill.id
	target_general.skills[msg.msg.pos + 1].cfgId = cfgId
	target_general.skills[msg.msg.pos + 1].lv = 1 -- 这里功能有缺陷，技能的升级并没有存储，todo
	table.insert(skill.belong_generals, msg.msg.gId)
	CMD.send2client({
		seq = msg.seq,
		msg = {
			cfgId = cfgId,
			pos = msg.msg.pos,	
			gId = msg.msg.gId,
		},
		name = protoid.general_upSkill,
		code = error_code.success,
	})
	PUBLIC.saveGeneral(self, msg.msg.gId)
	PUBLIC.pushGeneral(self,msg.msg.gId)
end

-- 升级技能
REQUEST[protoid.general_lvSkill] = function(self,args)
	local target_general = PUBLIC.getGeneralById(self, args.msg.gId)
	if not target_general then
		print("没有找到武将")
		return CMD.send2client({
			seq = args.seq,
			name = protoid.general_lvSkill,
			code = error_code.GeneralNotFound,
		})
	end
	local pos = args.msg.pos + 1
	local skillid = target_general.skills[pos].cfgId
	local skill_config = all_skills.map[skillid]
	-- 当前等级
	local current_lv = target_general.skills[pos].lv
	if current_lv >= #skill_config.levels then
		print("技能已满级")
		return CMD.send2client({
			seq = args.seq,
			name = protoid.general_lvSkill,
			code = error_code.OutSkillLimit,
		})
	end
	-- 升级技能
	target_general.skills[pos].lv = current_lv + 1
	
	CMD.send2client({
		seq = args.seq,
		msg = {
			pos = args.msg.pos,
			gId = args.msg.gId,
		},
		name = protoid.general_lvSkill,
		code = error_code.success,
	})
	PUBLIC.saveGeneral(self, args.msg.gId)
	PUBLIC.pushGeneral(self,args.msg.gId)
end