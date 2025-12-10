local CRYPT = require "lcrypt"

local crypt = {
  -- HEX编码/解码
  hexencode = CRYPT.hexencode,
  hexdecode = CRYPT.hexdecode,
  -- URL编码/解码
  urlencode = CRYPT.urlencode,
  urldecode = CRYPT.urldecode,
}

-- UUID与GUID
require "mycrypt.id"(crypt)

-- 安全哈希与摘要算法
require "mycrypt.sha"(crypt)

-- 哈希消息认证码算法
require "mycrypt.hmac"(crypt)

-- 冗余校验算法
require "mycrypt.checksum"(crypt)

-- Base64编码/解码算法
require "mycrypt.b64"(crypt)

-- RC4算法
require "mycrypt.rc4"(crypt)

-- AES对称加密算法
require "mycrypt.aes"(crypt)

-- DES对称加密算法
require "mycrypt.des"(crypt)

-- 密钥交换算法
require "mycrypt.dh"(crypt)

-- 商用国密算法
require "mycrypt.sm"(crypt)

-- 非对称加密算法
require "mycrypt.rsa"(crypt)

-- 一些特殊算法
require "mycrypt.utils"(crypt)

return crypt