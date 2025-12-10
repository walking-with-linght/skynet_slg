
-- 定义一些常量
PDEFINE = {}


PDEFINE.EXCHANGERATE = 1

PDEFINE.LIMIT_HISTORY = 20

PDEFINE.CONFIG = {
    MaxBet = 93372036854775807,
}

-- 货币 (同步旧的定义)
PDEFINE.CURRENCY = {
    COIN        = 1, -- 豆子
    DIAMOND     = 2, -- 钻石
}

-- gold日志类型
PDEFINE.COIN = {
    HandredBet                   = 62, -- 百人场投注
    GameCost                     = 54, --游戏结算 
    -- 56  On-stage fee    台费
    -- 62  Handred Bet    百人场投注
    -- 68  Handred Cancel Bet  百人场撤销投注
    -- 64  Bet Return    投注返还 比如龙虎斗赢了先返还投的注
    -- 54  Game Cost     游戏结算 最终游戏的输赢
    -- 63  Player wins tax money  税收 赢了的抽水
}

-- gold日志类型
PDEFINE.DIAMOND = {
    Bet = 1,
    ADMIN                   = 999, --后台
}

--几个ticktok的房间类型，5代表5秒结算一次
G_GAME_STATE_TIME = {
    [1] = {
        bet = 30,
        open = 5,
        settlement = 5,
    },
    [2] = {
        bet = 30,
        open = 15,
        settlement = 5,
    },
    [3] = {
        bet = 30,
        open = 30,
        settlement = 5,
    },
    [4] = {
        bet = 30,
        open = 60,
        settlement = 5,
    },
}

GAME_BET_TYPE = {
    down = 1,
    up = 2,
}
-- ticktok每个房间下发的走势图数量
TICKTOK_TYPE_COUNT = {
    [1] = 100,
    [2] = 100,
    [3] = 100,
    [4] = 100,
}
-- 游戏 10001 - 10005  crash plinko dice limbo mines
PDEFINE.GAME =
{
    GT_Crash        = 10001,
    GT_Plinko       = 10002,
    GT_Dice         = 10003,
    GT_Limbo        = 10004,
    GT_Mines        = 10005,
    GT_Ticktok      = 20001,
}

G_GAME_ID =
{
    crash        = 10001,
    plinko       = 10002,
    dice         = 10003,
    limbo        = 10004,
    mines        = 10005,
    ticktok      = 20001,
}
G_GAME_NAME =
{
    [10001]        = "crash",
    [10002]        = "plinko",
    [10003]        = "dice",
    [10004]        = "limbo",
    [10005]        = "mines",
    [20001]        = "ticktok",
}


-- 为了存库保证顺序一致
G_GAME_NAME_LIST =
{
    { id = 10003, name = "dice" },
    { id = 10004, name = "limbo" },
    { id = 10005, name = "mines" },
    { id = 10001, name = "crash" },
    { id = 10002, name = "plinko" },
    -- { id = 20001, name = "ticktok" },
}


PDEFINE.ROOM = {
    OK                      =  0,
}


PDEFINE.RET =
{
    UNDEFINE = 0,
    SUCCESS = 0,

    Code = {
        ROOM_NOPLAY_DISMISSION          =1, --=房间未开局解散/>
        ROOM_ADMIN_DISMISSION           =2, --=服务器解散房间/>
        ROOM_VERSION_NOTMATCH           =3, --=版本不匹配/>
        ROOM_NOMAL_GOLD_LIMIT           =4, --=金币房金币限制/>
        ROOM_NOPLAY_TIPS                =5, --=约战超时僵死提示/>
        ROOM_AA_NOPLAY_DISMISSION       =6, --=AA房间未开局解散/>
        ROOM_OUT_TIME_NOR_AGREE         =7, --=超时不同意解散/>
        ROOM_NOMAL_GOLD_BANKRUPTCY      =8, --=金币破产/>
        ROOM_NOMAL_BROAD                =9, --=跑马灯广播消息/>
        ROOM_FAIL_DISMISSION            =10, --=解散房间失败消息/>
        ROOM_TAX_TIPS                   =11, --=房费提示消息/>
        ROOM_TICK_USER                  =12, --=踢出玩家房间消息/>
        ROOM_GOLD_NOT_ENOUGH            =13, --=玩家金币不够/>
        ROOM_QIECUO_NOPLAY_DISMISSION   =14, --=切磋场房间未开局解散/>
        ROOM_COMM_TIPS                  =15, --=体验场提示消息/>
        ROOM_UNSTART_TIPS               =16, --=长时间未开始提示消息/>
        ROOM_PLAY_DISMISSION            =17, --=游戏中玩家解散房间/>
        ROOM_HUND_TICK                  =18, --=百人场踢出挂机用户/>
        ROOM_NOMAL_TIPS                 =19, --=通用提示类型/>         
        ROOM_DIAMOND_NOT_ENOUGH         =20, --=通用提示类型/>         
        ROOM_API_ERROR                  =21, --=通用提示类型/>         
    },
}

PDEFINE.CommMessageType =
{
    Box = 1,
    Text = 2,
}

REDES_DB = {
    BACK = 0,
    GAME = 1,
    ROBOT = 2,
    BLOG = 15,
}

GAME_SERVER_NAME = {
    test = "测试服",
    debug = "开发服",
    online = "正式服",
}

----------------------------------------
MSG_TYPE = {
    S2C = 0,
}
-- 心跳超时时间
HEARTBEAT_TIMEOUT = 5 * 5 -- 5秒*5 次