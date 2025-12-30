
-- 定义一些常量


----------------------------------------
MSG_TYPE = {
    S2C = 0,
}
-- 心跳超时时间
HEARTBEAT_TIMEOUT = 10 * 10 -- 10秒*10 次


GeneralState = {
    Normal = 0,
    Convert = 1,
}
Facility_Addition_Type = {
    TypeDurable   		= 1,	--耐久
    TypeCost 			= 2,
    TypeArmyTeams 		= 3,	--队伍数量
    TypeSpeed			= 4,	--速度
    TypeDefense			= 5,	--防御
    TypeStrategy		= 6,	--谋略
    TypeForce			= 7,	--攻击武力
    TypeConscriptTime	= 8, --征兵时间
    TypeReserveLimit 	= 9, --预备役上限
    TypeUnkonw			= 10,
    TypeHanAddition 	= 11,
    TypeQunAddition		= 12,
    TypeWeiAddition 	= 13,
    TypeShuAddition 	= 14,
    TypeWuAddition		= 15,
    TypeDealTaxRate		= 16,--交易税率
    TypeWood			= 17,
    TypeIron			= 18,
    TypeGrain			= 19,
    TypeStone			= 20,
    TypeTax				= 21,--税收
    TypeExtendTimes		= 22,--扩建次数
    TypeWarehouseLimit 	= 23,--仓库容量
    TypeSoldierLimit 	= 24,--带兵数量
    TypeVanguardLimit 	= 25,--前锋数量
}


Market_Type = {
    TypeWood = 0,
    TypeIron = 1,
    TypeStone = 2,
    TypeGrain = 3,
}
Market_Type_Server = {
    [Market_Type.TypeWood] = "wood",
    [Market_Type.TypeIron] = "iron",
    [Market_Type.TypeStone] = "stone",
    [Market_Type.TypeGrain] = "grain",
}

Chat_Type = {
    World = 0,
    Guild = 1,
    Private = 2,
    System = 3,
}
Chat_Type_Server = {
    [Chat_Type.World] = "World",
    [Chat_Type.Guild] = "Guild",
    [Chat_Type.Private] = "Private",
    [Chat_Type.System] = "System",
}


Facility_Type = {
    Main = 1,   -- 主城
    JiaoChang = 14, -- 校场
    TongShuaiTing = 15, -- 统帅厅
    JiShi = 16, -- 集市
    MBS = 17, -- 募兵所
}

Army_Cmd = {
	ArmyCmdIdle        = 0, --空闲
	ArmyCmdAttack      = 1, --攻击
	ArmyCmdDefend      = 2, --驻守
	ArmyCmdReclamation = 3, --屯垦
	ArmyCmdBack        = 4, --撤退
	ArmyCmdConscript   = 5, --征兵
	ArmyCmdTransfer    = 6, --调动
}