SKYNET_ROOT := ../../skynet/
LUA_STATICLIB := $(SKYNET_ROOT)3rd/lua/liblua.a

LUA_LIB ?= $(LUA_STATICLIB)
LUA_INC ?= $(SKYNET_ROOT)3rd/lua

SRC_DIR = ./
MCSERVICE_PATH = ../cservice/
CFLAGS := -g -O2 -Wall -I$(LUA_INC) $(MYCFLAGS)

# 自动检测平台并设置共享库编译选项
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    # macOS
    SHARED := -fPIC -dynamiclib -Wl,-undefined,dynamic_lookup
    CC ?= gcc
else
    # Linux 和其他 Unix 系统
    SHARED := -fPIC -shared
    CC ?= gcc
endif

# jemalloc 配置
JE_MALLOC_INC := $(SKYNET_ROOT)3rd/jemalloc/include/jemalloc
JE_MALLOC_LIB := $(SKYNET_ROOT)3rd/jemalloc/lib/libjemalloc_pic.a

MCSERVICE = skiplist time aoi rand openssl cjson tz lcrypt pb consistenthash lfs
all :  $(foreach v, $(MCSERVICE), $(MCSERVICE_PATH)$(v).so) \
	$(MCSERVICE_PATH)lutil.so \
	$(MCSERVICE_PATH)lkcp.so \
	$(MCSERVICE_PATH)utf8.so \
	$(MCSERVICE_PATH)crab.so

.PHONY : all clean cleanall

$(MCSERVICE_PATH) :
	mkdir -p $(MCSERVICE_PATH)

# skiplist - 链接 jemalloc 库
# skiplist - 添加 jemalloc 命名空间
# skiplist - 简化版本，不使用内存统计
$(MCSERVICE_PATH)skiplist.so : $(SRC_DIR)/skiplist.c $(SRC_DIR)/lua-skiplist.c | $(MCSERVICE_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ -I$(SKYNET_ROOT)skynet-src

$(MCSERVICE_PATH)time.so : $(SRC_DIR)/lua-time.c | $(MCSERVICE_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ -I$(SKYNET_ROOT)skynet-src

$(MCSERVICE_PATH)lutil.so : $(SRC_DIR)/lutil.c | $(MCSERVICE_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@

$(MCSERVICE_PATH)lkcp.so : $(SRC_DIR)/lkcp.c $(SRC_DIR)kcp/ikcp.c $(SRC_DIR)kcp/ikcp.h | $(MCSERVICE_PATH)
	$(CC) $(CFLAGS) $(SHARED) $(filter %.c,$^) -o $@

$(MCSERVICE_PATH)aoi.so : $(SRC_DIR)/aoi.c $(SRC_DIR)/lua-aoi.c $(SRC_DIR)/aoi.h | $(MCSERVICE_PATH)
	$(CC) $(CFLAGS) $(SHARED) $(filter %.c,$^) -o $@

$(MCSERVICE_PATH)utf8.so : $(SRC_DIR)/lua-utf8.c | $(MCSERVICE_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@

$(MCSERVICE_PATH)crab.so : $(SRC_DIR)/lua-crab.c | $(MCSERVICE_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@

$(MCSERVICE_PATH)lfs.so : $(SRC_DIR)/lua-lfs/src/lfs.c | $(MCSERVICE_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@

$(MCSERVICE_PATH)rand.so : $(SRC_DIR)/lua-rand/rand.c | $(MCSERVICE_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@

clean :
	rm -f $(MCSERVICE_PATH)*.so