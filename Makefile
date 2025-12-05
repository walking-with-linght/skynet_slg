include platform.mk

LUA_CLIB_PATH ?= luaclib
CSERVICE_PATH ?= cservice

SKYNET_BUILD_PATH ?= .

CFLAGS = -g -O2 -Wall -I$(LUA_INC) $(MYCFLAGS)
# CFLAGS += -DUSE_PTHREAD_LOCK

# lua

LUA_STATICLIB := 3rd/lua/liblua.a
LUA_LIB ?= $(LUA_STATICLIB)
LUA_INC ?= 3rd/lua

$(LUA_STATICLIB) :
	cd 3rd/lua && $(MAKE) CC='$(CC) -std=gnu99' $(PLAT)

# https : turn on TLS_MODULE to add https support

# 自动检测平台
UNAME_S := $(shell uname -s)

# TLS 配置
TLS_MODULE = ltls

ifeq ($(UNAME_S),Darwin)
    # macOS - 使用 Homebrew 的 OpenSSL
    OPENSSL_PREFIX := $(shell brew --prefix openssl@3 2>/dev/null || brew --prefix openssl 2>/dev/null)
    ifneq ($(OPENSSL_PREFIX),)
        TLS_LIB = $(OPENSSL_PREFIX)/lib
        TLS_INC = $(OPENSSL_PREFIX)/include
    else
        $(warning OpenSSL not found via Homebrew, disabling TLS support)
        TLS_MODULE =
        TLS_LIB =
        TLS_INC =
    endif
else
    # Linux - 使用系统 OpenSSL
    TLS_LIB = /usr/lib
    TLS_INC = /usr/include
endif

# 检查 OpenSSL 头文件是否存在
ifneq ($(TLS_MODULE),)
    ifeq ($(wildcard $(TLS_INC)/openssl/evp.h),)
        $(warning OpenSSL headers not found at $(TLS_INC)/openssl/, disabling TLS support)
        TLS_MODULE =
        TLS_LIB =
        TLS_INC =
    endif
endif

# jemalloc

JEMALLOC_STATICLIB := 3rd/jemalloc/lib/libjemalloc_pic.a
JEMALLOC_INC := 3rd/jemalloc/include/jemalloc

all : jemalloc
	
.PHONY : jemalloc update3rd

MALLOC_STATICLIB := $(JEMALLOC_STATICLIB)

$(JEMALLOC_STATICLIB) : 3rd/jemalloc/Makefile
	cd 3rd/jemalloc && $(MAKE) CC=$(CC) 

3rd/jemalloc/autogen.sh :
	git submodule update --init

3rd/jemalloc/Makefile : | 3rd/jemalloc/autogen.sh
	cd 3rd/jemalloc && ./autogen.sh --with-jemalloc-prefix=je_ --enable-prof

jemalloc : $(MALLOC_STATICLIB)

update3rd :
	rm -rf 3rd/jemalloc && git submodule update --init

# skynet

CSERVICE = snlua logger gate harbor
LUA_CLIB = skynet \
  client \
  bson md5 sproto lpeg rand openssl cjson tz lcrypt pb consistenthash lfs $(TLS_MODULE)

LUA_CLIB_SKYNET = \
  lua-skynet.c lua-seri.c \
  lua-socket.c \
  lua-mongo.c \
  lua-netpack.c \
  lua-memory.c \
  lua-multicast.c \
  lua-cluster.c \
  lua-crypt.c lsha1.c \
  lua-sharedata.c \
  lua-stm.c \
  lua-debugchannel.c \
  lua-datasheet.c \
  lua-sharetable.c \
  \

SKYNET_SRC = skynet_main.c skynet_handle.c skynet_module.c skynet_mq.c \
  skynet_server.c skynet_start.c skynet_timer.c skynet_error.c \
  skynet_harbor.c skynet_env.c skynet_monitor.c skynet_socket.c socket_server.c \
  malloc_hook.c skynet_daemon.c skynet_log.c

all : \
  $(SKYNET_BUILD_PATH)/skynet \
  $(foreach v, $(CSERVICE), $(CSERVICE_PATH)/$(v).so) \
  $(foreach v, $(LUA_CLIB), $(LUA_CLIB_PATH)/$(v).so) 

$(SKYNET_BUILD_PATH)/skynet : $(foreach v, $(SKYNET_SRC), skynet-src/$(v)) $(LUA_LIB) $(MALLOC_STATICLIB)
	$(CC) $(CFLAGS) -o $@ $^ -Iskynet-src -I$(JEMALLOC_INC) $(LDFLAGS) $(EXPORT) $(SKYNET_LIBS) $(SKYNET_DEFINES)

$(LUA_CLIB_PATH) :
	mkdir $(LUA_CLIB_PATH)

$(CSERVICE_PATH) :
	mkdir $(CSERVICE_PATH)

define CSERVICE_TEMP
  $$(CSERVICE_PATH)/$(1).so : service-src/service_$(1).c | $$(CSERVICE_PATH)
	$$(CC) $$(CFLAGS) $$(SHARED) $$< -o $$@ -Iskynet-src
endef

$(foreach v, $(CSERVICE), $(eval $(call CSERVICE_TEMP,$(v))))

$(LUA_CLIB_PATH)/skynet.so : $(addprefix lualib-src/,$(LUA_CLIB_SKYNET)) | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ -Iskynet-src -Iservice-src -Ilualib-src

$(LUA_CLIB_PATH)/bson.so : lualib-src/lua-bson.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -Iskynet-src $^ -o $@

$(LUA_CLIB_PATH)/md5.so : 3rd/lua-md5/md5.c 3rd/lua-md5/md5lib.c 3rd/lua-md5/compat-5.2.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-md5 $^ -o $@ 

$(LUA_CLIB_PATH)/client.so : lualib-src/lua-clientsocket.c lualib-src/lua-crypt.c lualib-src/lsha1.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ -lpthread

$(LUA_CLIB_PATH)/sproto.so : lualib-src/sproto/sproto.c lualib-src/sproto/lsproto.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -Ilualib-src/sproto $^ -o $@ 

$(LUA_CLIB_PATH)/rand.so : 3rd/lua-rand/rand.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-rand $^ -o $@ 

$(LUA_CLIB_PATH)/tz.so : 3rd/lua-tz/src/tz.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-tz/src $^ -o $@ 

$(LUA_CLIB_PATH)/consistenthash.so : 3rd/lua-consistent-hash/consistenthash.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-consistent-hash/src $^ -o $@ 

$(LUA_CLIB_PATH)/lfs.so : 3rd/lua-lfs/src/lfs.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-lfs/src $^ -o $@

$(LUA_CLIB_PATH)/ddz.so : 3rd/ddz/AutoLock.cpp 3rd/ddz/LuaYunCheng.cpp 3rd/ddz/PermutationCombine.cpp 3rd/ddz/YunChengAI.cpp | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/ddz $^ -o $@ -lpthread

$(LUA_CLIB_PATH)/cjson.so : 3rd/lua-cjson/lua_cjson.c 3rd/lua-cjson/strbuf.c 3rd/lua-cjson/fpconv.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-cjson $^ -o $@

$(LUA_CLIB_PATH)/ltls.so : lualib-src/ltls.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -Iskynet-src -L$(TLS_LIB) -I$(TLS_INC) $^ -o $@ -lssl -lcrypto

$(LUA_CLIB_PATH)/lpeg.so : 3rd/lpeg/lpcap.c 3rd/lpeg/lpcode.c 3rd/lpeg/lpprint.c 3rd/lpeg/lptree.c 3rd/lpeg/lpvm.c 3rd/lpeg/lpcset.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lpeg $^ -o $@ 

# 递归查找 3rd/lua-openssl 目录及其子目录下的所有 .c 文件和 .h 文件
SSL_SRCS := $(shell find 3rd/lua-openssl -name '*.c')
SSL_HDRS := $(shell find 3rd/lua-openssl -name '*.h')
SSL_INCS := $(sort $(dir $(SSL_HDRS)))  # 获取所有子目录路径
SSL_CFLAGS = $(CFLAGS)
SSL_CFLAGS += $(foreach dir,$(SSL_INCS),-I$(dir))  # 添加递归搜索路径

$(LUA_CLIB_PATH)/openssl.so : $(SSL_SRCS) | $(LUA_CLIB_PATH)
	$(CC) $(SSL_CFLAGS) $(SHARED) $^ -o $@ -L$(TLS_LIB) -I$(TLS_INC) -lssl

CRYPT_SRCS := $(shell find 3rd/lua-crypt/src -name '*.c')
$(LUA_CLIB_PATH)/lcrypt.so :  $(CRYPT_SRCS) | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-crypt/src -L$(TLS_LIB) -I$(TLS_INC) $^ -o $@ -lssl -lcrypto

$(LUA_CLIB_PATH)/pb.so : 3rd/lua-protobuf/pb.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-protobuf $^ -o $@

$(LUA_CLIB_PATH)/navigation.so : 3rd/slg-navigation/luabinding.c 3rd/slg-navigation/map.c 3rd/slg-navigation/jps.c 3rd/slg-navigation/fibheap.c 3rd/slg-navigation/smooth.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/slg-navigation $^ -o $@

$(LUA_CLIB_PATH)/hex_grid.so : 3rd/lua-hex-grid/luabinding.c 3rd/lua-hex-grid/hex_grid.c 3rd/lua-hex-grid/node_freelist.c 3rd/lua-hex-grid/intlist.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-hex-grid $^ -o $@

clean :
	rm -f $(SKYNET_BUILD_PATH)/skynet $(CSERVICE_PATH)/*.so $(LUA_CLIB_PATH)/*.so && \
  rm -rf $(SKYNET_BUILD_PATH)/*.dSYM $(CSERVICE_PATH)/*.dSYM $(LUA_CLIB_PATH)/*.dSYM

cleanall: clean
ifneq (,$(wildcard 3rd/jemalloc/Makefile))
	cd 3rd/jemalloc && $(MAKE) clean && rm Makefile
endif
	cd 3rd/lua && $(MAKE) clean
	rm -f $(LUA_STATICLIB)

