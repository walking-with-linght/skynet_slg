require "mods.m_base"
require "mods.m_skill"
require "mods.m_armys"

require "mods.m_generals"
require "mods.m_citys"
-- m_facility必须在m_citys之后加载，因为m_citys需要用到m_facility
require "mods.m_facility"
require "mods.m_resource"
require "mods.m_chat"