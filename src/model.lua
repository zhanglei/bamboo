module(..., package.seeall)
local socket = require 'socket'
local mih = require 'bamboo.model-indexhash'

local tinsert, tremove = table.insert, table.remove
local format = string.format

local db = BAMBOO_DB


local List = require 'lglib.list'
local rdstring = require 'bamboo.redis.string'
local rdlist = require 'bamboo.redis.list'
local rdset = require 'bamboo.redis.set'
local rdzset = require 'bamboo.redis.zset'
local rdfifo = require 'bamboo.redis.fifo'
local rdzfifo = require 'bamboo.redis.zfifo'
local rdhash = require 'bamboo.redis.hash'


local getModelByName  = bamboo.getModelByName
local dcollector= 'DELETED:COLLECTOR'
local rule_manager_prefix = '_RULE_INDEX_MANAGER:'
local rule_query_result_pattern = '_RULE:%s:%s'   -- _RULE:Model:num
local rule_sortby_manager_prefix = '_RULE_INDEX_SORTBY_MANAGER:'
local rule_sortby_result_pattern = '_RULE_SORTBY:%s:%s'
local rule_index_query_sortby_divider = ' |^|^| '
local rule_index_divider = ' ^_^ '
local QuerySet
local Model

-----------------------------------------------------------------
local rdactions = {
	['string'] = {},
	['list'] = {},
	['set'] = {},
	['zset'] = {},
	['hash'] = {},
	['MANY'] = {},
	['FIFO'] = {},
	['ZFIFO'] = {},
	['LIST'] = {},
}

rdactions['string'].save = rdstring.save
rdactions['string'].update = rdstring.update
rdactions['string'].retrieve = rdstring.retrieve
rdactions['string'].remove = rdstring.remove
rdactions['string'].add = rdstring.add
rdactions['string'].has = rdstring.has
rdactions['string'].num = rdstring.num

rdactions['list'].save = rdlist.save
rdactions['list'].update = rdlist.update
rdactions['list'].retrieve = rdlist.retrieve
rdactions['list'].remove = rdlist.remove
--rdactions['list'].add = rdlist.add
rdactions['list'].add = rdlist.append
rdactions['list'].has = rdlist.has
--rdactions['list'].num = rdlist.num
rdactions['list'].num = rdlist.len

rdactions['set'].save = rdset.save
rdactions['set'].update = rdset.update
rdactions['set'].retrieve = rdset.retrieve
rdactions['set'].remove = rdset.remove
rdactions['set'].add = rdset.add
rdactions['set'].has = rdset.has
rdactions['set'].num = rdset.num

rdactions['zset'].save = rdzset.save
rdactions['zset'].update = rdzset.update
--rdactions['zset'].retrieve = rdzset.retrieve
rdactions['zset'].retrieve = rdzset.retrieveWithScores
rdactions['zset'].remove = rdzset.remove
rdactions['zset'].add = rdzset.add
rdactions['zset'].has = rdzset.has
rdactions['zset'].num = rdzset.num

rdactions['hash'].save = rdhash.save
rdactions['hash'].update = rdhash.update
rdactions['hash'].retrieve = rdhash.retrieve
rdactions['hash'].remove = rdhash.remove
rdactions['hash'].add = rdhash.add
rdactions['hash'].has = rdhash.has
rdactions['hash'].num = rdhash.num

rdactions['FIFO'].save = rdfifo.save
rdactions['FIFO'].update = rdfifo.update
rdactions['FIFO'].retrieve = rdfifo.retrieve
rdactions['FIFO'].remove = rdfifo.remove
rdactions['FIFO'].add = rdfifo.push
rdactions['FIFO'].has = rdfifo.has
rdactions['FIFO'].num = rdfifo.len

rdactions['ZFIFO'].save = rdzfifo.save
rdactions['ZFIFO'].update = rdzfifo.update
rdactions['ZFIFO'].retrieve = rdzfifo.retrieve
rdactions['ZFIFO'].remove = rdzfifo.remove
rdactions['ZFIFO'].add = rdzfifo.push
rdactions['ZFIFO'].has = rdzfifo.has
rdactions['ZFIFO'].num = rdzfifo.num

rdactions['LIST'] = rdactions['list']
rdactions['MANY'] = rdactions['zset']

local getStoreModule = function (store_type)
	local store_module = rdactions[store_type]
	assert( store_module, "[Error] store type must be one of 'string', 'list', 'set', 'zset' or 'hash'.")
	return store_module
end


-----------------------------------------------------------------

local function getCounterName(self)
	return self.__name + ':__counter'
end 

-- return a string
local function getCounter(self)
    return db:get(getCounterName(self)) or '0'
end;

local function getNameIdPattern(self)
	return self.__name + ':' + self.id
end

local function getNameIdPattern2(self, id)
	return self.__name + ':' + tostring(id)
end

local function getFieldPattern(self, field)
	return getNameIdPattern(self) + ':' + field
end 

local function getFieldPattern2(self, id, field)
	return getNameIdPattern2(self, id) + ':' + field
end 

-- return the key of some string like 'User'
--
local function getClassName(self)
	if type(self) ~= 'table' then return nil end
	return self.__tag:match('%.(%w+)$')
end

-- return the key of some string like 'User:__index'
--
local function getIndexKey(self)
	return getClassName(self) + ':__index'
end

local function getClassIdPattern(self)
	return getClassName(self) + self.id
end

local function getCustomKey(self, key)
	return getClassName(self) + ':custom:' + key
end

local function getCustomIdKey(self, key)
	return getClassName(self) + ':' + self.id + ':custom:'  + key
end

local function getCacheKey(self, key)
	return getClassName(self) + ':cache:' + key
end

local function getCachetypeKey(self, key)
	return 'CACHETYPE:' + getCacheKey(self, key)
end

local function getDynamicFieldKey(self, key)
	return getClassName(self) + ':dynamic_field:' + key
end

local function getDynamicFieldIndex(self)
	return getClassName(self) + ':dynamic_field:__index'
end

local function makeModelKeyList(self, ids)
	local key_list = List()
	for _, v in ipairs(ids) do
		key_list:append(getNameIdPattern2(self, v))
	end
	return key_list
end


-- can be called by instance and class
local isUsingFulltextIndex = function (self)
	local model = self
	if isInstance(self) then model = getModelByName(self:classname()) end
	if bamboo.config.fulltext_index_support and rawget(model, '__use_fulltext_index') then
		return true
	else
		return false
	end
end

local isUsingRuleIndex = function ()
	if bamboo.config.rule_index_support == false then
		return false
	end
	return true
end

local specifiedRulePrefix = function (rule_type)
	if rule_type == 'query' then
		return rule_manager_prefix, rule_query_result_pattern
	else
		--  rule_type == 'sortby'
		return rule_sortby_manager_prefix, rule_sortby_result_pattern
	end
end

-- in model global index cache (backend is zset),
-- check the existance of some member by its id (score)
--
local function checkExistanceById(self, id)
	local index_key = getIndexKey(self)
	local r = db:zrangebyscore(index_key, id, id)
	if #r == 0 then 
		return false, ''
	else
		-- return the first element, for r is a list
		return true, r[1]
	end
end

-- return the model part and the id part
-- if normal case, get the model string and return item directly
-- if UNFIXED case, split the UNFIXED model:id and return  
-- this function doesn't suite ANYSTRING case
local function seperateModelAndId(item)
	local link_model, linked_id
	local link_model_str
	link_model_str, linked_id = item:match('^(%w+):(%d+)$')
	assert(link_model_str)
	assert(linked_id)
	link_model = getModelByName(link_model_str)
	assert(link_model)

	return link_model, linked_id
end

local makeObject = function (self, data)
	-- if data is invalid, return nil
	if not isValidInstance(data) then 
		print("[Warning] @makeObject - Object is invalid.")
		-- print(debug.traceback())
		return nil 
	end
	-- XXX: keep id as string for convienent, because http and database are all string
	
	local fields = self.__fields
	for k, fld in pairs(fields) do
		-- ensure the correction of field description table
		checkType(fld, 'table')
		-- convert the number type field
			
    	if fld.foreign then
			local st = fld.st
			-- in redis, we don't save MANY foreign key in db, but we want to fill them when
			-- form lua object
			if st == 'MANY' then
				data[k] = 'FOREIGN MANY ' .. fld.foreign
			elseif st == 'FIFO' then
				data[k] = 'FOREIGN FIFO ' .. fld.foreign
			elseif st == 'ZFIFO' then
				data[k] = 'FOREIGN ZFIFO ' .. fld.foreign
      		elseif st == 'LIST' then
        		data[k] = 'FOREIGN LIST ' .. fld.foreign
      		end
    	else
      		if fld.type == 'number' then
        		data[k] = tonumber(data[k])
			elseif fld.type == 'boolean' then
				data[k] = data[k] == 'true' and true or false
			end
		end

	end

	-- generate an object
	-- XXX: maybe can put 'data' as parameter of self()
	local obj = self()
	table.update(obj, data)
	return obj

end


local clearFtIndexesOnDeletion = function (instance)
	local model_key = getNameIdPattern(instance)
	local words = db:smembers('_RFT:' + model_key)
	db:pipeline(function (p)
		for _, word in ipairs(words) do
			p:srem(format('_FT:%s:%s', instance.__name, word), model_key)
		end
	end)
	-- clear the reverse fulltext key
	db:del('_RFT:' + model_key)
end



------------------------------------------------------------
-- this function can only be called by Model
-- @param model_key:
--
local getFromRedis = function (self, model_key)
	-- here, the data table contain ordinary field, ONE foreign key, but not MANY foreign key
	-- all fields are strings 
	local data = db:hgetall(model_key)
	return makeObject(self, data)

end 

-- 

local getFromRedisPipeline = function (self, ids)
	local key_list = makeModelKeyList(self, ids)
	--DEBUG(key_list)
	
	-- all fields are strings
	local data_list = db:pipeline(function (p) 
		for _, v in ipairs(key_list) do
			p:hgetall(v)
		end
	end)

	local objs = QuerySet()
	local nils = {}
	local obj
	for i, v in ipairs(data_list) do
		obj = makeObject(self, v)
		if obj then tinsert(objs, obj)
		else tinsert(nils, ids[i])
		end
	end

	return objs, nils
end 

-- fields must not be empty 
local getPartialFromRedisPipeline = function (self, ids, fields)
	tinsert(fields, 'id')
	local key_list = makeModelKeyList(self, ids)
	-- DEBUG('key_list', key_list, 'fields', fields)
	
	local data_list = db:pipeline(function (p) 
		for _, v in ipairs(key_list) do
			p:hmget(v, unpack(fields))
		end
	end)
	
	local proto_fields = self.__fields
	-- all fields are strings
	-- every item is data_list now is the values according to 'fields'
	local objs = QuerySet()
	-- here, data_list is fields' order values
	for _, v in ipairs(data_list) do
		local item = {}
		for i, key in ipairs(fields) do
			-- v[i] is the value of ith key
			item[key] = v[i]
			
			local fdt = proto_fields[key]
			if fdt and fdt.type then
				if fdt.type == 'number' then
					item[key] = tonumber(item[key])
				elseif fdt.type == 'boolean' then
					item[key] = item[key] == 'true' and true or false
				end
			end
		end
		-- only has valid field other than id can be checked as fit object
		if item[fields[1]] ~= nil then
			-- tinsert(objs, makeObject(self, item))
			-- here, we jumped the makeObject step, to promote performance
			tinsert(objs, item)
		end
	end

	return objs
end 

-- for use in "User:id" as each item key
local getFromRedisPipeline2 = function (pattern_list)
	-- 'list' store model and id info
	local model_list = List()
	for _, v in ipairs(pattern_list) do
		local model, id = seperateModelAndId(v)
		model_list:append(model)
	end
	
	-- all fields are strings
	local data_list = db:pipeline(function (p) 
		for _, v in ipairs(pattern_list) do
			p:hgetall(v)
		end
	end)

	local objs = QuerySet()
	local nils = {}
	local obj
	for i, model in ipairs(model_list) do
		obj = makeObject(model, data_list[i])
		if obj then tinsert(objs, obj) 
		else tinsert(nils, pattern_list[i])
		end
	end

	return objs, nils
end 


--------------------------------------------------------------
-- Restore Fake Deletion
-- called by Some Model: self, not instance
local restoreFakeDeletedInstance = function (self, id)
	checkType(tonumber(id),  'number')
	local model_key = getNameIdPattern2(self, id)
	local index_key = getIndexKey(self)

	local instance = getFromRedis(self, 'DELETED:' + model_key)
	if not instance then return nil end
	-- rename the key self
	db:rename('DELETED:' + model_key, model_key)
	local fields = self.__fields
	-- in redis, restore the associated foreign key-value
	for k, v in pairs(instance) do
		local fld = fields[k]
		if fld and fld.foreign then
			local key = model_key + ':' + k
			if db:exists('DELETED:' + key) then
				db:rename('DELETED:' + key, key)
			end
		end
	end

	-- when restore, the instance's index cache was restored.
	db:zadd(index_key, instance.id, instance.id)
	-- remove from deleted collector
	db:zrem(dcollector, model_key)

    if bamboo.config.index_hash then 
        mih.index(instance,true);--create hash index
    end

	return instance
end


local retrieveObjectsByForeignType = function (foreign, list)
	if foreign == 'ANYSTRING' then
		-- return string list directly
		return QuerySet(list)
	elseif foreign == 'UNFIXED' then
		return getFromRedisPipeline2(list)
	else
		-- foreign field stores "id, id, id" list
		local model = getModelByName(foreign)
		return getFromRedisPipeline(model, list)
	end
	
end


--------------------------------------------------------------------------------
if bamboo.config.fulltext_index_support then require 'mmseg' end
-- Full Text Search utilities
-- @param instance the object to be full text indexes
local makeFulltextIndexes = function (instance)
	
	local ftindex_fields = instance['__fulltext_index_fields']
	if isFalse(ftindex_fields) then return false end

	local words
	for _, v in ipairs(ftindex_fields) do
		-- parse the fulltext field value
		words = mmseg.segment(instance[v])
		for _, word in ipairs(words) do
			-- only index word length larger than 1
			if string.utf8len(word) >= 2 then
				-- add this word to global word set
				db:sadd(format('_fulltext_words:%s', instance.__name), word)
				-- add reverse fulltext index such as '_RFT:model:id', type is set, item is 'word'
				db:sadd(format('_RFT:%s', getNameIdPattern(instance)), word)
				-- add fulltext index such as '_FT:word', type is set, item is 'model:id'
				db:sadd(format('_FT:%s:%s', instance.__name, word), instance.id)
			end
		end
	end
	
	return true	
end

local wordSegmentOnFtIndex = function (self, ask_str)
	local search_tags = mmseg.segment(ask_str)
	local tags = List()
	for _, tag in ipairs(search_tags) do
		if string.utf8len(tag) >= 2 and db:sismember(format('_fulltext_words:%s', self.__name), tag) then
			tags:append(tag)
		end
	end
	return tags
end


local searchOnFulltextIndexes = function (self, tags, n)
	if #tags == 0 then return List() end
	
	local rlist = List()
	local _tmp_key = "__tmp_ftkey"
	if #tags == 1 then
		db:sinterstore(_tmp_key, format('_FT:%s:%s', self.__name, tags[1]))
	else
		local _args = {}
		for _, tag in ipairs(tags) do
			table.insert(_args, format('_FT:%s:%s', self.__name, tag))
		end
		-- XXX, some afraid
		db:sinterstore(_tmp_key, unpack(_args))
	end
	
	local limits
	if n and type(n) == 'number' and n > 0 then
		limits = {0, n}
	else
		limits = nil
	end
	-- sort and retrieve
	local ids =  db:sort(_tmp_key, {limit=limits, sort="desc"})
	-- return objects
	return getFromRedisPipeline(self, ids)
end

--------------------------------------------------------------------------------
-- The bellow four assertations, they are called only by class, instance or query set
--
-------------------------------------------
-- judge if it is a class
--
_G['isClass'] = function (t)
	if t.isClass then
		if type(t.isClass) == 'function' then
			return t:isClass()
		else
			return false
		end
	else 
		return false
	end
end

-------------------------------------------
-- judge if it is an instance
-- 
_G['isInstance'] = function (t)
	if t.isInstance then 
		if type(t.isInstance) == 'function' then
			return t:isInstance()
		else
			return false
		end
	else 
		return false
	end
end

---------------------------------------------------------------
-- judge if it is an empty object.
-- the empty rules are defined by ourselves, see follows.
-- 
_G['isValidInstance'] = function (obj)
	if isFalse(obj) then return false end
	checkType(obj, 'table')
	
	for k, v in pairs(obj) do
		if type(k) == 'string' then
			if k ~= 'id' then
				return true
			end
		end
	end
	
	return false
end;


_G['isQuerySet'] = function (self)
	if isList(self)
	and rawget(self, '__spectype') == nil and self.__spectype == 'QuerySet' 
	and self.__tag == 'Object.Model'
	then return true
	else return false
	end
end

-------------------------------------------------------------
--
_G['I_AM_QUERY_SET'] = function (self)
	assert(isQuerySet(self), "[Error] This caller is not a QuerySet.")
end

_G['I_AM_CLASS'] = function (self)
	assert(self.isClass, '[Error] The caller is not a valid class.')
	assert(self:isClass(), '[Error] This function is only allowed to be called by class.') 
end

_G['I_AM_CLASS_OR_QUERY_SET'] = function (self)
	assert(self.isClass, '[Error] The caller is not a valid class.')
	assert(self:isClass() or isQuerySet(self), '[Error] This function is only allowed to be called by class or query set.')
end

_G['I_AM_INSTANCE'] = function (self)
	assert(self.isInstance, '[Error] The caller is not a valid instance.')
	assert(self:isInstance(), '[Error] This function is only allowed to be called by instance.')
end

_G['I_AM_INSTANCE_OR_QUERY_SET'] = function (self)
	assert(self.isInstance, '[Error] The caller is not a valid instance.')
	assert(self:isInstance() or isQuerySet(self), '[Error] This function is only allowed to be called by instance or query set.')
end

_G['I_AM_CLASS_OR_INSTANCE'] = function (self)
	assert(self.isClass or self.isInstance, '[Error] The caller is not a valid class or instance.')
	assert(self:isClass() or self:isInstance(), '[Error] This function is only allowed to be called by class or instance.')
end


------------------------------------------------------------------------
-- Query Function Set
-- for convienent, import them into _G directly
------------------------------------------------------------------------
local closure_collector = {}
local upvalue_collector = {}
local uglystr = '___hashindex^*_#@[]-+~~!$$$$'

_G['eq'] = function ( cmp_obj )
	local t = function (v)
	-- XXX: here we should not open the below line. v can be nil
		if v == uglystr then return nil, 'eq', cmp_obj; end--only return params
		
        if v == cmp_obj then
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'eq', cmp_obj}
	return t
end

_G['uneq'] = function ( cmp_obj )
	local t = function (v)
	-- XXX: here we should not open the below line. v can be nil
		if v == uglystr then return nil, 'uneq', cmp_obj; end

		if v ~= cmp_obj then
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'uneq', cmp_obj}
	return t
end

_G['lt'] = function (limitation)
	limitation = tonumber(limitation) or limitation
	local t = function (v)
        if v == uglystr then return nil, 'lt', limitation; end

		local nv = tonumber(v) or v
		if nv and nv < limitation then
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'lt', limitation}
	return t
end

_G['gt'] = function (limitation)
	limitation = tonumber(limitation) or limitation
	local t = function (v)
        if v == uglystr then return nil, 'gt', limitation; end

		local nv = tonumber(v) or v
		if nv and nv > limitation then
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'gt', limitation}
	return t
end


_G['le'] = function (limitation)
	limitation = tonumber(limitation) or limitation
	local t = function (v)
        if v == uglystr then return nil, 'le', limitation; end

		local nv = tonumber(v) or v
		if nv and nv <= limitation then
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'le', limitation}
	return t
end

_G['ge'] = function (limitation)
	limitation = tonumber(limitation) or limitation
	local t = function (v)
        if v == uglystr then return nil, 'ge', limitation; end

		local nv = tonumber(v) or v
		if nv and nv >= limitation then
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'ge', limitation}
	return t
end

_G['bt'] = function (small, big)
	small = tonumber(small) or small
	big = tonumber(big) or big	
	local t = function (v)
        if v == uglystr then return nil, 'bt', {small, big}; end

		local nv = tonumber(v) or v
		if nv and nv > small and nv < big then
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'bt', small, big}
	return t
end

_G['be'] = function (small, big)
	small = tonumber(small) or small
	big = tonumber(big) or big	
	local t = function (v)
        if v == uglystr then return nil, 'be', {small,big}; end

		local nv = tonumber(v) or v
		if nv and nv >= small and nv <= big then
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'be', small, big}
	return t
end

_G['outside'] = function (small, big)
	small = tonumber(small) or small
	big = tonumber(big) or big	
	local t = function (v)
        if v == uglystr then return nil, 'outside',{small,big}; end

		local nv = tonumber(v) or v
		if nv and nv < small and nv > big then
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'outside', small, big}
	return t
end

_G['contains'] = function (substr)
	local t = function (v)
        if v == uglystr then return nil, 'contains', substr; end

		v = tostring(v)
		if v:contains(substr) then 
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'contains', substr}
	return t
end

_G['uncontains'] = function (substr)
	local t = function (v)
        if v == uglystr then return nil, 'uncontains', substr; end

		v = tostring(v)
		if not v:contains(substr) then 
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'uncontains', substr}
	return t
end


_G['startsWith'] = function (substr)
	local t = function (v)
        if v == uglystr then return nil, 'startsWith', substr; end

		v = tostring(v)
		if v:startsWith(substr) then 
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'startsWith', substr}
	return t
end

_G['unstartsWith'] = function (substr)
	local t = function (v)
        if v == uglystr then return nil, 'unstartsWith', substr; end

		v = tostring(v)
		if not v:startsWith(substr) then 
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'unstartsWith', substr}
	return t
end


_G['endsWith'] = function (substr)
	local t = function (v)
        if v == uglystr then return nil, 'endsWith', substr; end
		v = tostring(v)
		if v:endsWith(substr) then 
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'endsWith', substr}
	return t
end

_G['unendsWith'] = function (substr)
	local t = function (v)
        if v == uglystr then return nil, 'unendsWith', substr; end
		v = tostring(v)
		if not v:endsWith(substr) then 
			return true
		else
			return false
		end
	end
	closure_collector[t] = {'unendsWith', substr}
	return t
end

_G['inset'] = function (...)
	local args = {...}
	local t = function (v)
        if v == uglystr then return nil, 'inset', args; end
		v = tostring(v)
		for _, val in ipairs(args) do
			-- once meet one, ok
			if tostring(val) == v then
				return true
			end
		end
		
		return false
	end
	closure_collector[t] = {'inset', ...}
	return t
end

_G['uninset'] = function (...)
	local args = {...}
	local t = function (v)
        if v == uglystr then return nil, 'uninset', args; end
		v = tostring(v)
		for _, val in ipairs(args) do
			-- once meet one, false
			if tostring(val) == v then
				return false
			end
		end
		
		return true
	end
	closure_collector[t] = {'uninset', ...}
	return t
end

-------------------------------------------------------------------
--
local collectRuleFunctionUpvalues = function (query_args)
	local upvalues = upvalue_collector
	for i=1, math.huge do
		local name, v = debug.getupvalue(query_args, i)
		if not name then break end
		local ctype = type(v)
		local table_has_metatable = false
		if ctype == 'table' then
			table_has_metatable = getmetatable(v) and true or false
		end
		-- because we could not collect the upvalues whose type is 'table', print warning here
		if type(v) == 'function' or table_has_metatable then 
			print"[Warning] @collectRuleFunctionUpvalues of filter - bamboo has no ability to collect the function upvalue whose type is 'function' or 'table' with metatable."
			return false
		end
			
		if ctype == 'table' then
			upvalues[#upvalues + 1] = { name, serialize(v), type(v) }
		else
			upvalues[#upvalues + 1] = { name, tostring(v), type(v) }
		end
	end
	
	return true
end

-----------------------------------------------------------------------
-- query_str_iden is at least ''
local compressSortByArgs = function (query_str_iden, sortby_args)
	local strs = {}
	for i, v in ipairs(sortby_args) do
		local ctype = type(v)
		if ctype == 'string' or ctype == 'nil' then
			tinsert(strs, v)
		elseif ctype == 'function' then
			tinsert(strs, string.dump(v))
		end
	end
	
	local sortby_str_iden = table.concat(strs, ' ')
	return query_str_iden .. rule_index_query_sortby_divider .. sortby_str_iden
end

local extractSortByArgs = function (sortby_str_iden)
	local sortby_args = sortby_str_iden:split(' ')
	-- [1] is string, [2] is nil or string, [3] is nil or function
	-- [4] is nil or string, [5] is nil or string, [6] is nil or function
	local key = sortby_args[1] ~= 'nil' and sortby_args[1] or nil
	local direction = sortby_args[2] == 'desc' and 'desc' or 'asc'
	local func = (sortby_args[3] ~= nil and sortby_args[3] ~= 'nil') and loadstring(sortby_args[3]) or function (a, b)
		local af = a[key] 
		local bf = b[key]
		if af and bf then
			if direction == 'asc' then
				return af < bf
			elseif direction == 'desc' then
				return af > bf
			end
		else
			return nil
		end
	end
	
	return func
end


local canInstanceFitQueryRuleAndFindProperPosition = function (self, combine_str_iden)
	print('enter canInstanceFitQueryRuleAndFindProperPosition')
	local p
	local id_list = {}
	local query_str_iden, sortby_str_iden = combine_str_iden:splitout(rule_index_query_sortby_divider)
	print(query_str_iden, sortby_str_iden)
	local flag = true

	-- how to separate the can't fit rule and the all rule ({})
	if query_str_iden ~= '' then
		flag = canInstanceFitQueryRule (self, query_str_iden)
	end
	
	print(flag)
	if flag then
		local manager_key = rule_sortby_manager_prefix .. self.__name
		local score = db:zscore(manager_key, combine_str_iden)
		local item_key = rule_sortby_result_pattern:format(self.__name, math.floor(score))
		id_list = db:lrange(item_key, 0, -1)
		local length = #id_list
		local model = self:getClass()
		print(model)			
		local func = extractSortByArgs(sortby_str_iden)
		print(func)

		local l, r = 1, #id_list
		local left_obj
		local right_obj
		local bflag, left_flag, right_flag, pflag

		left_obj = model:getById(id_list[l])
		right_obj = model:getById(id_list[r])
		if left_obj == nil or right_obj == nil then 
			return nil, id_list[#id_list], #id_list 
		end
		bflag = func(left_obj, right_obj)
		
		p = l
		while (r ~= l) do
			print('in sort auto, l, r, p', l, r, p)
			if left_obj == nil or right_obj == nil then 
				return nil, id_list[#id_list], #id_list 
			end
			left_flag = func(left_obj, self)
			right_flag = func(self, right_obj)
			
			if bflag == left_flag and bflag == right_flag then
			-- between
				p = math.floor((l + r)/2)
			elseif bflag == left_flag then
			-- on the right hand
				p = r + 1
				break
			elseif bflag == right_flag then
			-- on the left hand
				p = l - 1
				break
			end
			
			local mobj = model:getById(id_list[p])
			if mobj == nil then 
				return nil, id_list[#id_list], #id_list 
			end
			
			pflag = func(mobj, self)
			if pflag == bflag then
				l = p
			else
				r = p
			end

			left_obj = model:getById(id_list[l])
			right_obj = model:getById(id_list[r])
			if r - l <= 1 then r = l end
		end
	
		-- now p is the insert position
		local mobj = model:getById(id_list[p])
		if mobj then
			pflag = func(mobj, self)
			if pflag ~= bflag then
				p = p - 1
			end
		end
	end
	

	print(id_list[p], p)
	return flag, id_list[p], p
end





-------------------------------------------------------------------------
local compressQueryArgs = function (query_args)
	local out = {}
	local qtype = type(query_args)
	if qtype == 'table' then
		if table.isEmpty(query_args) then return '' end
		
		if query_args[1] == 'or' then tinsert(out, 'or')
		else tinsert(out, 'and')
		end
		query_args[1] = nil
		tinsert(out, '|')
	
		local queryfs = {}
		for kf in pairs(query_args) do
			tinsert(queryfs, kf)
		end
		table.sort(queryfs)
	
		for _, k in ipairs(queryfs) do
			v = query_args[k]
			tinsert(out, k)
			if type(v) == 'string' then
				tinsert(out, v)			
			else
				local queryt_iden = closure_collector[v]
				for _, item in ipairs(queryt_iden) do
					tinsert(out, item)		
				end
			end
			tinsert(out, '|')		
		end
		-- clear the closure_collector
		closure_collector = {}
		
		-- restore the first element, avoiding side effect
		query_args[1] = out[1]	

	elseif qtype == 'function' then
		tinsert(out, 'function')
		tinsert(out, '|')	
		tinsert(out, string.dump(query_args))
		tinsert(out, '|')			
		for _, pair in ipairs(upvalue_collector) do
			tinsert(out, pair[1])	-- key
			tinsert(out, pair[2])	-- value
			tinsert(out, pair[3])	-- value type			
		end

		-- clear the upvalue_collector
		upvalue_collector = {}
	end

	-- use a delemeter to seperate obviously
	return table.concat(out, rule_index_divider)
end

local extractQueryArgs = function (qstr)
	local query_args
	
	--DEBUG(string.len(qstr))		
	if qstr:startsWith('function') then
		local startpoint = qstr:find('|') or 1
		local endpoint = qstr:rfind('|') or -1
		fpart = qstr:sub(startpoint + 6, endpoint - 6) -- :trim()
		apart = qstr:sub(endpoint + 6, -1) -- :trim()
		-- now fpart is the function binary string
		query_args = loadstring(fpart)
		-- now query_args is query function
		if not isFalse(apart) then
			-- item 1 is key, item 2 is value, item 3 is value type, item 4 is key .... 
			local flat_upvalues = apart:split(rule_index_divider)
			for i=1, #flat_upvalues / 3 do
				local vtype = flat_upvalues[3*i]
				local key = flat_upvalues[3*i - 2]
				local value = flat_upvalues[3*i - 1]
				if vtype == 'table' then
					value = deserialize(value)
				elseif vtype == 'number' then
					value = tonumber(value)
				elseif vtype == 'boolean' then
					value = loadstring('return ' .. value)()
				elseif vtype == 'nil' then
					value = nil
				end
				-- set upvalues
				debug.setupvalue(query_args, i, value)
			end
		end
	else
	
		local endpoint = -1
		qstr = qstr:sub(1, endpoint - 1)
		print('qstr---', qstr)
		local _qqstr = qstr:split('|')
		local logic = _qqstr[1]:sub(1, -6)
		query_args = {logic}
		ptable(_qqstr)
		for i=2, #_qqstr do
			local str = _qqstr[i]
			local kt = str:splittrim(rule_index_divider):slice(2, -2)
			ptable(kt)
			-- kt[1] is 'key', [2] is 'closure', [3] .. are closure's parameters
			local key = kt[1]
			local closure = kt[2]
			if #kt > 2 then
				local _args = {}
				for j=3, #kt do
					tinsert(_args, kt[j])
				end
				-- compute closure now
				query_args[key] = _G[closure](unpack(_args))
			else
				-- no args, means this 'closure' is a string
				query_args[key] = closure
			end
		end
	end
	
	return query_args	
end


local checkLogicRelation = function (obj, query_args, logic_choice, model)
	-- NOTE: query_args can't contain [1]
	-- here, obj may be object or string 
	-- when obj is string, query_args must be function;
	-- when query_args is table, obj must be table, and must be real object.
	local flag = logic_choice
	if type(query_args) == 'table' then
		local fields = model and model.__fields or obj.__fields
		for k, v in pairs(query_args) do
			-- to redundant query condition, once meet, jump immediately
			if not fields[k] then flag=false; break end

			if type(v) == 'function' then
				flag = v(obj[k])
			else
				flag = (obj[k] == v)
			end
			---------------------------------------------------------------
			-- logic_choice,       flag,      action,          append?
			---------------------------------------------------------------
			-- true (and)          true       next field       --
			-- true (and)          false      break            no
			-- false (or)          true       break            yes
			-- false (or)          false      next field       --
			---------------------------------------------------------------
			if logic_choice ~= flag then break end
		end
	else
		-- call this query args function
		flag = query_args(obj)
	end
	
	return flag
end

local canInstanceFitQueryRule = function (self, qstr)
	local query_args = extractQueryArgs(qstr)
	--DEBUG(query_args)
	local logic_choice = true
	if type(query_args) == 'table' then logic_choice = (query_args[1] == 'and'); query_args[1]=nil end
	return checkLogicRelation(self, query_args, logic_choice)
end

-- here, qstr rule exist surely
local addInstanceToIndexOnRule = function (self, qstr, rule_type)
	local rule_manager_prefix, rule_result_pattern = specifiedRulePrefix(rule_type)

	local manager_key = rule_manager_prefix .. self.__name
	--DEBUG(self, qstr, manager_key)	
	local score = db:zscore(manager_key, qstr)
	local item_key = rule_result_pattern:format(self.__name, math.floor(score))

	local flag, cmpid, p
	if rule_result_pattern == rule_query_result_pattern then
		flag = canInstanceFitQueryRule(self, qstr) 
		cmpid = self.id
	else
		flag, cmpid, p = canInstanceFitQueryRuleAndFindProperPosition(self, qstr)
	end
	
	local success = 1
	if flag then
		local options = { watch = item_key, cas = true, retry = 2 }
		db:transaction(options, function(db)
			-- if previously added, remove it first, if no, just no effects
			-- but this may change the default object index orders
			--db:lrem(item_key, 0, self.id)
			--db:rpush(item_key, self.id)
			if cmpid == nil then
				if p < 1 then
					db:lpush(item_key, self.id)
				else
					db:rpush(item_key, self.id)
				end
			else
			-- insert a new id after the old same id
				success = db:linsert(item_key, 'AFTER', cmpid, self.id)
			end
			--print('success----', success)
			-- success == -1, means no cmpid found, means self.id is a new item
			if success == -1 then
				db:rpush(item_key, self.id)
			else
				-- the case using 'save' api to save the old instance
				if cmpid == self.id then
					-- delete the old one id
					db:lrem(item_key, 1, self.id)
				end
			
			end
			-- update the float score to integer
			db:zadd(manager_key, math.floor(score), qstr)
			db:expire(item_key, bamboo.config.rule_expiration or bamboo.RULE_LIFE)
		
		end)
	end
	return flag
end

local updateInstanceToIndexOnRule = function (self, qstr, rule_type)
	local rule_manager_prefix, rule_result_pattern = specifiedRulePrefix(rule_type)

	local manager_key = rule_manager_prefix .. self.__name
	local score = db:zscore(manager_key, qstr)
	local item_key = rule_result_pattern:format(self.__name, math.floor(score))

	local flag, cmpid, p
	if rule_result_pattern == rule_query_result_pattern then
		flag = canInstanceFitQueryRule(self, qstr) 
		cmpid = self.id
	else
		flag, cmpid, p = canInstanceFitQueryRuleAndFindProperPosition(self, qstr)
	end
	db:transaction(function(db)
		if flag then
			-- consider the two end cases
			if cmpid == nil then
				db:lrem(item_key, 1, self.id)
				if p < 1 then
					db:lpush(item_key, self.id)
				else
					db:rpush(item_key, self.id)
				end
			else
				-- self's compared value has been changed
				if cmpid ~= self.id then
					-- delete old self first, insert self to proper position
					db:lrem(item_key, 1, self.id)
					db:linsert(item_key, 'AFTER', cmpid, self.id)
				else
					-- cmpid == self.id, means use query rule only, keep the old position
					db:linsert(item_key, 'AFTER', cmpid, self.id)
					db:lrem(item_key, 1, self.id)
				end
			end
		else
			-- doesn't fit any more, delete the old one id
			db:lrem(item_key, 1, self.id)
		end
			
		-- this may change the default object index orders
--		db:lrem(item_key, 0, self.id)
--		if flag then
--			db:rpush(item_key, self.id)	
--		end
		db:expire(item_key, bamboo.config.rule_expiration or bamboo.RULE_LIFE)
	end)
	return flag
end

local delInstanceToIndexOnRule = function (self, qstr, rule_type)
	local rule_manager_prefix, rule_result_pattern = specifiedRulePrefix(rule_type)

	local manager_key = rule_manager_prefix .. self.__name
	local score = db:zscore(manager_key, qstr)
	local item_key = rule_result_pattern:format(self.__name, math.floor(score))

	local options = { watch = item_key, cas = true, retry = 2 }
	db:transaction(options, function(db)
		db:lrem(item_key, 0, self.id)
		-- if delete to empty list, update the rule score to float
		if not db:exists(item_key) then   
			db:zadd(manager_key, score + 0.1, qstr)
		end
		db:expire(item_key, bamboo.config.rule_expiration or bamboo.RULE_LIFE)
	end)
	return self
end

local INDEX_ACTIONS = {
	['save'] = addInstanceToIndexOnRule,
	['update'] = updateInstanceToIndexOnRule,
	['del'] = delInstanceToIndexOnRule
}

local updateIndexByRules = function (self, action, rule_type)
	local rule_manager_prefix, rule_result_pattern = specifiedRulePrefix(rule_type)

	local manager_key = rule_manager_prefix .. self.__name
	local qstr_list = db:zrange(manager_key, 0, -1)
	local action_func = INDEX_ACTIONS[action]
	for _, qstr in ipairs(qstr_list) do
		action_func(self, qstr, rule_type)
	end
end

-- can be reentry
local addIndexToManager = function (self, str_iden, obj_list, rule_type)
	local rule_manager_prefix, rule_result_pattern = specifiedRulePrefix(rule_type)
	
	local manager_key = rule_manager_prefix .. self.__name
	-- add to index manager
	local score = db:zscore(manager_key, str_iden)
	-- if score then return end
	local new_score
	if not score then
		-- when it is a new rule 
		new_score = db:zcard(manager_key) + 1
		-- use float score represent empty rule result index
		if #obj_list == 0 then new_score = new_score + 0.1 end
		db:zadd(manager_key, new_score, str_iden)
	else
		-- when rule result is expired, re enter this function
		new_score = score
	end
	if #obj_list == 0 then return end
	
	local item_key = rule_result_pattern:format(self.__name, math.floor(new_score))
	local options = { watch = item_key, cas = true, retry = 2 }
	db:transaction(options, function(db)
		if not db:exists(item_key) then
			-- generate the index item, use list
			db:rpush(item_key, unpack(obj_list))
		end
		-- set expiration to each index item
		db:expire(item_key, bamboo.config.rule_expiration or bamboo.RULE_LIFE)
	end)
end

local getIndexFromManager = function (self, str_iden, getnum, rule_type)
	local rule_manager_prefix, rule_result_pattern = specifiedRulePrefix(rule_type)

	local manager_key = rule_manager_prefix .. self.__name
	-- get this rule's socre
	local score = db:zscore(manager_key, str_iden)
	-- if has no score, means it is not rule indexed, 
	-- return nil directly
	if not score then 
		return nil
	end
	
	-- if score is float, means its rule result is empty, return empty query set
	if score % 1 ~= 0 then
		return (not getnum) and List() or 0
	end
	
	-- score is integer, not float, and rule result doesn't exist, means its rule result is expired now,
	-- need to retreive again, so return nil
	local item_key = rule_result_pattern:format(self.__name, score)
	if not db:exists(item_key) then 
		return nil
	end
	
	-- update expiration
	db:expire(item_key, bamboo.config.rule_expiration or bamboo.RULE_LIFE)
	-- rule result is not empty, and not expired, retrieve them
	if not getnum then
		-- return a list
		return List(db:lrange(item_key, 0, -1))
	else
		-- return the number of this list
		return db:llen(item_key)
	end
end


--------------------------------------------------------------
-- this function can be called by instance or class
--
local delFromRedis = function (self, id)
	assert(self.id or id, '[Error] @delFromRedis - must specify an id of instance.')
	local model_key = id and getNameIdPattern2(self, id) or getNameIdPattern(self)
	local index_key = getIndexKey(self)

    --del hash index 
    if bamboo.config.index_hash then 
        mih.indexDel(self);
    end
	
	local fields = self.__fields
	-- in redis, delete the associated foreign key-value store
	for k, v in pairs(self) do
		local fld = fields[k]
		if fld and fld.foreign then
			local key = model_key + ':' + k
			db:del(key)
		end
	end

	-- delete the key self
	db:del(model_key)
	-- delete the index in the global model index zset
	db:zremrangebyscore(index_key, self.id or id, self.id or id)
	
	-- clear fulltext index, only when it is instance
	if isUsingFulltextIndex(self) and self.id then
		clearFtIndexesOnDeletion(self)
	end
	if isUsingRuleIndex(self) and self.id then
		updateIndexByRules(self, 'del', 'query')
		updateIndexByRules(self, 'del', 'sortby')
	end
				
	-- release the lua object
	self = nil
end

--------------------------------------------------------------
-- Fake Deletion
--  called by instance
local fakedelFromRedis = function (self, id)
	assert(self.id or id, '[Error] @fakedelFromRedis - must specify an id of instance.')
	local model_key = id and getNameIdPattern2(self, id) or getNameIdPattern(self)
	local index_key = getIndexKey(self)

    --del hash index 
    if bamboo.config.index_hash then 
        mih.indexDel(self);
    end
	
	local fields = self.__fields
	-- in redis, delete the associated foreign key-value store
	for k, v in pairs(self) do
		local fld = fields[k]
		if fld and fld.foreign then
			local key = model_key + ':' + k
			if db:exists(key) then
				db:rename(key, 'DELETED:' + key)
			end
		end
	end

	-- rename the key self
	db:rename(model_key, 'DELETED:' + model_key)
	-- delete the index in the global model index zset
	-- when deleted, the instance's index cache was cleaned.
	db:zremrangebyscore(index_key, self.id or id, self.id or id)
	-- add to deleted collector
	rdzset.add(dcollector, model_key)
	
	-- clear fulltext index
	if isUsingFulltextIndex(self) and self.id then
		clearFtIndexesOnDeletion(self)
	end
	if isUsingRuleIndex(self) and self.id then
		updateIndexByRules(self, 'del', 'query')
		updateIndexByRules(self, 'del', 'sortby')
	end

	-- release the lua object
	self = nil
end


-- called by save
-- self is instance
local processBeforeSave = function (self, params)
    local indexfd = self.__indexfd
    local fields = self.__fields
    local store_kv = {}
    --- save an hash object
    -- 'id' are essential in an object instance
    tinsert(store_kv, 'id')
    tinsert(store_kv, self.id)		

    -- if parameters exist, update it
    if params and type(params) == 'table' then
		for k, v in pairs(params) do
			if k ~= 'id' and fields[k] then
				self[k] = tostring(v)
			end
		end
    end

    assert(not isFalse(self[indexfd]) , 
    	format("[Error] instance's index field %s's value must not be nil. Please check your model defination.", indexfd))

	-- check required field
	-- TODO: later we should update this to validate most attributes for each field
	for field, fdt in pairs(fields) do
		if fdt.required then
			assert(self[field], format("[Error] @processBeforeSave - this field '%s' is required but its' value is nil.", field))
		end
	end
		
    for k, v in pairs(self) do
		-- when save, need to check something
		-- 1. only save fields defined in model defination
		-- 2. don't save the functional member, and _parent
		-- 3. don't save those fields not defined in model defination
		-- 4. don't save those except ONE foreign fields, which are defined in model defination
		local fdt = fields[k]
		-- if v is nil, pairs will not iterate it, key will and should not be 'id'
		if fdt then
			if not fdt['foreign'] or ( fdt['foreign'] and fdt['st'] == 'ONE') then
				-- save
				tinsert(store_kv, k)
				tinsert(store_kv, v)		
			end
		end
    end

    return self, store_kv
end


------------------------------------------------------------------------
-- 
------------------------------------------------------------------------


------------------------------------------------------------------------
-- Model Define
-- Model is the basic object of Bamboo Database Abstract Layer
------------------------------------------------------------------------


Model = Object:extend {
	__tag = 'Object.Model';
	-- ATTEN: __name's value is not neccesary be equal strictly to the last word of __tag
	__name = 'Model';
	__desc = 'Model is the base of all models.';
	__fields = {
	    -- here, we don't put 'id' as a field
	    ['created_time'] = { type="number" },
	    ['lastmodified_time'] = { type="number" },
	    
	};
	__indexfd = "id";

	-- make every object creatation from here: every object has the 'id', 'created_time' and 'lastmodified_time' fields
	init = function (self, t)
		local t = t or {}
		local fields = self.__fields
		
		for field, fdt in pairs(fields) do
			-- assign to default value if exsits
			local tmp = t[field] or fdt.default
			if type(tmp) == 'function' then
				self[field] = tmp()
			else
				self[field] = tmp
			end
		end
	
		self.created_time = socket.gettime()
		self.lastmodified_time = self.created_time
		
		return self 
	end;
    

	toHtml = function (self, params)
		 I_AM_INSTANCE(self)
		 params = params or {}
		 
		 if params.field and type(params.field) == 'string' then
			 for k, v in pairs(params.attached) do
				 if v == 'html_class' then
					 self.__fields[params.field][k] = self.__fields[params.field][k] .. ' ' .. v
				 else
					 self.__fields[params.field][k] = v
				 end
			 end
			 
			 return (self.__fields[params.field]):toHtml(self, params.field, params.format)
		 end
		 
		 params.attached = params.attached or {}
		 
		 local output = ''
		 for field, fdt_old in pairs(self.__fields) do
			 local fdt = table.copy(fdt_old)
			 setmetatable(fdt, getmetatable(fdt_old))
			 for k, v in pairs(params.attached) do
				 if type(v) == 'table' then
					 for key, val in pairs(v) do
						 fdt[k] = fdt[k] or {}
						 fdt[k][key] = val
					 end
				 else
					 fdt[k] = v
				 end
			 end

			 local flag = true
			 params.filters = params.filters or {}
			 for k, v in pairs(params.filters) do
				 -- to redundant query condition, once meet, jump immediately
				 if not fdt[k] then
					 -- if k == 'vl' then self.__fields[field][k] = 0 end
					 if k == 'vl' then fdt[k] = 0 end
				 end

				 if type(v) == 'function' then
					 flag = v(fdt[k] or '')
					 if not flag then break end
				 else
					 if fdt[k] ~= v then flag=false; break end
				 end
			 end

			 if flag then
				 output = output .. fdt:toHtml(self, field, params.format or nil)
			 end

		 end

		 return output
	 end,


	--------------------------------------------------------------------
	-- Class Functions. Called by class object.
	--------------------------------------------------------------------

    getRankByIndex = function (self, name)
		I_AM_CLASS(self)

		local index_key = getIndexKey(self)
		-- id is the score of that index value
		local rank = db:zrank(index_key, tostring(name))
		return tonumber(rank)
    end;

	-- return id queried by index
	--
    getIdByIndex = function (self, name)
		I_AM_CLASS(self)
		local index_key = getIndexKey(self)
		-- id is the score of that index value
		local idstr = db:zscore(index_key, tostring(name))
		return tonumber(idstr)
    end;
    
    -- return name query by id
	-- 
    getIndexById = function (self, id)
		I_AM_CLASS(self)
		if type(tonumber(id)) ~= 'number' then return nil end		

		local flag, name = checkExistanceById(self, id)
		if isFalse(flag) or isFalse(name) then return nil end

		return name
    end;

    -- return instance object by id
	--
	getById = function (self, id)
		I_AM_CLASS(self)
		--DEBUG(id)
		if type(tonumber(id)) ~= 'number' then return nil end
		
		-- check the existance in the index cache
		if not checkExistanceById(self, id) then return nil end
		-- and then check the existance in the key set
		local key = getNameIdPattern2(self, id)
		if not db:exists(key) then return nil end
		--DEBUG(key)
		return getFromRedis(self, key)
	end;
	
	getByIds = function (self, ids)
		I_AM_CLASS(self)
		assert(type(ids) == 'table')
		
		return getFromRedisPipeline(self, ids)
	end;

	-- return instance object by name
	--
	getByIndex = function (self, name)
		I_AM_CLASS(self)
		local id = self:getIdByIndex(name)
		if not id then return nil end

		return self:getById (id)
	end;
	
	-- return a list containing all ids of all instances belong to this Model
	--
	allIds = function (self, find_rev)
		I_AM_CLASS(self)
		local index_key = getIndexKey(self)
		local all_ids 
		if find_rev == 'rev' then
			all_ids = db:zrevrange(index_key, 0, -1, 'withscores')
		else
			all_ids = db:zrange(index_key, 0, -1, 'withscores')
		end
		local ids = List()
		for _, v in ipairs(all_ids) do
			-- v[1] is the 'index value', v[2] is the 'id'
			ids:append(v[2])
		end
		
		return ids
	end;
	
	-- slice the ids list, start from 1, support negative index (-1)
	-- 
	sliceIds = function (self, start, stop, is_rev)
		I_AM_CLASS(self)
		checkType(start, stop, 'number', 'number')
		local index_key = getIndexKey(self)
		local all_ids = List(db:zrange(index_key, 0, -1, 'withscores'))
		all_ids = all_ids:slice(start, stop, is_rev)
		local ids = List()
		for _, v in ipairs(all_ids) do
			-- v[1] is the 'index value', v[2] is the 'id'
			ids:append(v[2])
		end
		
		return ids
	end;	
	
	-- return all instance objects belong to this Model
	-- 
	all = function (self, find_rev)
		I_AM_CLASS(self)
		local all_ids = self:allIds(find_rev)
		return getFromRedisPipeline(self, all_ids)
	end;

	-- slice instance object list, support negative index (-1)
	-- 
	slice = function (self, start, stop, is_rev)
		-- !slice method won't be open to query set, because List has slice method too.
		I_AM_CLASS(self)
		local ids = self:sliceIds(start, stop, is_rev)
		return getFromRedisPipeline(self, ids)
	end;
	
	-- this is a magic function
	-- return all the keys belong to this Model (or this model's parent model)
	-- all elements in returning list are string
	--
	allKeys = function (self)
		I_AM_CLASS(self)
		return db:keys(self.__name + ':*')
	end;
	
	-- return the actual number of the instances
	--
	numbers = function (self)
		I_AM_CLASS(self)
		return db:zcard(getIndexKey(self))
	end;
	
	-- return the first instance found by query set
	--
	get = function (self, query_args, find_rev)
		-- XXX: may cause effective problem
		-- every time 'get' will cause the all objects' retrieving
		local objs = self:filter(query_args, nil, nil, find_rev, 'get')
		if objs then 
			return objs[1]
		else
			return obj
		end
	end;

	--- fitler some instances belong to this model
	-- @param query_args: query arguments in a table
	-- @param start: specify which index to start slice, note: this is the position after filtering 
	-- @param stop: specify the end of slice
	-- @param is_rev: specify the direction of the search result, 'rev'
	-- @return: query_set, an object list (query set)
	-- @note: this function can be called by class object and query set
	filter = function (self, query_args, start, stop, is_rev, is_get)
		I_AM_CLASS_OR_QUERY_SET(self)
		assert(type(query_args) == 'table' or type(query_args) == 'function', '[Error] the query_args passed to filter must be table or function.')
		if start then assert(type(start) == 'number', '[Error] @filter - start must be number.') end
		if stop then assert(type(stop) == 'number', '[Error] @filter - stop must be number.') end
		if is_rev then assert(type(is_rev) == 'string', '[Error] @filter - is_rev must be string.') end
		
		local is_query_set = false
		if isQuerySet(self) then is_query_set = true end
		local is_args_table = (type(query_args) == 'table')
		local logic = 'and'
		
		local query_str_iden, is_capable_press_rule = '', true
		local is_using_rule_index = isUsingRuleIndex()
		if is_using_rule_index then
			if type(query_args) == 'function' then
				is_capable_press_rule = collectRuleFunctionUpvalues(query_args)
			end
			
			if is_capable_press_rule then
				-- make query identification string
				query_str_iden = compressQueryArgs(query_args)

				-- check index
				-- XXX: Only support class now, don't support query set, maybe query set doesn't need this feature
				local id_list = getIndexFromManager(self, query_str_iden, nil, 'query')
				if type(id_list) == 'table' then
					if #id_list == 0 then
						return QuerySet()
					else
						-- #id_list > 0
						if is_get == 'get' then
							id_list = (is_rev == 'rev') and List{id_list[#id_list]} or List{id_list[1]}
						else	
							-- now id_list is a list containing all id of instances fit to this query_args rule, so need to slice
							id_list = id_list:slice(start, stop, is_rev)
						end
						
						-- if have this list, return objects directly
						if #id_list > 0 then
							return getFromRedisPipeline(self, id_list)
						end
					end
				end
				-- else go ahead
			end
		end
		
		if is_args_table then

			if query_args and query_args['id'] then
				-- remove 'id' query argument
				print("[Warning] get and filter don't support search by id, please use getById.")
				-- print(debug.traceback())
				-- query_args['id'] = nil
				return nil
			end

			-- if query table is empty, return slice instances
			if isFalse(query_args) then 
				local start = start or 1
				local stop = stop or -1
				local nums = self:numbers()
				return self:slice(start, stop, is_rev)
			end

			-- normalize the 'and' and 'or' logic
			if query_args[1] then
				assert(query_args[1] == 'or' or query_args[1] == 'and', 
					"[Error] The logic should be 'and' or 'or', rather than: " .. tostring(query_args[1]))
				if query_args[1] == 'or' then
					logic = 'or'
				end
				query_args[1] = nil
			end
		end
		
		local all_ids = {}
		if is_query_set then
			-- if self is query set, we think of all_ids as object list, rather than id string list
			all_ids = self
			-- nothing in id list, return empty table
			if #all_ids == 0 then return QuerySet() end
		
		end
		
		-- create a query set
		local query_set = QuerySet()
		local logic_choice = (logic == 'and')
		local partially_got = false

		-- walkcheck can process full object and partial object
		local walkcheck = function (objs, model)
			for i, obj in ipairs(objs) do
				-- check the object's legalery, only act on valid object
				local flag = checkLogicRelation(obj, query_args, logic_choice, model)
				
				-- if walk to this line, means find one 
				if flag then
					tinsert(query_set, obj)
				end
			end
		end
		
		--DEBUG('all_ids', all_ids)
		if is_query_set then
			local objs = all_ids
			-- objs are already integrated instances
			walkcheck(objs)			
		else
            local hash_index_query_args = {};
            local hash_index_flag = false;
            local raw_filter_flag = false;

            if type(query_args) == 'function' then
                hash_index_flag = false;
                raw_filter_flag = true;
            elseif bamboo.config.index_hash then
                for field,value in pairs(query_args) do 
                    if self.__fields[field].index_type ~= nil then 
                        hash_index_query_args[field] = value;
                        query_args[field] = nil; 
                        hash_index_flag = true;
                    else
                        raw_filter_flag = true;
                    end
                end
            else
                raw_filter_flag = true;
                hash_index_flag = false;
            end


            if hash_index_flag then 
                all_ids = mih.filter(self,hash_index_query_args,logic);
            else
			    -- all_ids is id string list
    			all_ids = self:allIds()
            end

            if raw_filter_flag then 
	    		local qfs = {}
	    		if is_args_table then
		    		for k, _ in pairs(query_args) do
			    		tinsert(qfs, k)
				    end
					table.sort(qfs)
    			end
			
				local objs, nils
				if #qfs == 0 then
					-- collect nothing, use 'hgetall' to retrieve, partially_got is false
					-- when query_args is function, do this
					objs, nils = getFromRedisPipeline(self, all_ids)
				else
					-- use hmget to retrieve, now the objs are partial objects
					-- qfs here must have key-value pair
					-- here, objs are not real objects, only ordinary table
					objs = getPartialFromRedisPipeline(self, all_ids, qfs)
					partially_got = true
				end
				walkcheck(objs, self)

				if bamboo.config.auto_clear_index_when_get_failed then
					-- clear model main index
					if not isFalse(nils) then
						local index_key = getIndexKey(self)
						-- each element in nils is the id pattern string, when clear, remove them directly
						for _, v in ipairs(nils) do
							db:zremrangebyscore(index_key, v, v)
						end
					end		
				end
            else
		        -- here, all_ids is the all instance id to query_args now
                --query_set = QuerySet(all_ids);
                for i,v in ipairs(all_ids) do 
                    tinsert(query_set,self:getById(tonumber(v)));
                end
            end
		end
		
		-- here, _t_query_set is the all instance fit to query_args now
		local _t_query_set = query_set
		
		if #query_set == 0 then
			if not is_query_set and is_using_rule_index and is_capable_press_rule then
				addIndexToManager(self, query_str_iden, {}, 'query')
			end
		else
			if is_get == 'get' then
				query_set = (is_rev == 'rev') and List {_t_query_set[#_t_query_set]} or List {_t_query_set[1]}
			else	
				-- now id_list is a list containing all id of instances fit to this query_args rule, so need to slice
				query_set = _t_query_set:slice(start, stop, is_rev)
			end

			-- if self is query set, its' element is always integrated
			-- if call by class
			if not is_query_set then
				-- retrieve all objects' id
				local id_list = {}
				for _, v in ipairs(_t_query_set) do
					tinsert(id_list, v.id)
				end
				-- add to index, here, we index all instances fit to query_args, rather than results applied extra limitation conditions
				if is_using_rule_index and is_capable_press_rule then
					addIndexToManager(self, query_str_iden, id_list, 'query')
				end
				
				-- if partially got previously, need to get the integrated objects now
				if partially_got then
					id_list = {}
					-- retrieve needed objects' id
					for _, v in ipairs(query_set) do
						tinsert(id_list, v.id)
					end
					query_set = getFromRedisPipeline(self, id_list)
				end
			end
		end
		
		local query_set_meta = getmetatable(query_set)
		-- passing this query_str_iden to later chains method call
		query_set_meta['query_str_iden'] = query_str_iden ~= '' and query_str_iden or false

		print('in filter ------------')
		ptable(query_set_meta)
		return query_set
	end;
    
    -- count the number of instance fit to some rule
	count = function (self, query_args)
		I_AM_CLASS(self)	
		local query_str_iden = compressQueryArgs(query_args)
		local ret = getIndexFromManager(self, query_str_iden, 'getnum', 'query')
		if not ret then
			ret = #self:filter(query_args)
		end
		return ret
	end;
	
	-------------------------------------------------------------------
	-- CUSTOM API
	--- seven APIs
	-- 1. setCustom
	-- 2. getCustom
	-- 3. delCustom
	-- 4. existCustom
	-- 5. updateCustom
	-- 6. addCustomMember
	-- 7. removeCustomMember
	-- 8. hasCustomMember
	-- 9. numCustom

    -- 10. incrCustom   only number
    -- 11. decrCustom   only number
	--
	--- five store type
	-- 1. string
	-- 2. list
	-- 3. set
	-- 4. zset
	-- 5. hash
    -- 6. fifo   , scores is the length of fifo
	-------------------------------------------------------------------
    
	-- store customize key-value pair to db
	-- now: st is string, and value is number 
    -- if no this key, the value is 0 before performing the operation
    incrCustom = function(self,key,step) 
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)
        db:incrby(custom_key,step or 1) 
    end;
    decrCustom = function(self,key,step) 
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)
        db:decrby(custom_key,step or 1);
    end;

	-- store customize key-value pair to db
	-- now: it support string, list and so on
    -- if fifo ,the scores is the length of the fifo
	setCustom = function (self, key, val, st, scores)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)

		if not st or st == 'string' then
			assert( type(val) == 'string' or type(val) == 'number',
					"[Error] @setCustom - In the string mode of setCustom, val should be string or number.")
			rdstring.save(custom_key, val)
		else
			-- checkType(val, 'table')
			local store_module = getStoreModule(st)
			store_module.save(custom_key, val, scores)
		end
		
		return self
	end;

	setCustomQuerySet = function (self, key, query_set, scores)
		I_AM_CLASS_OR_INSTANCE(self)
		I_AM_QUERY_SET(query_set)
		checkType(key, 'string')

		if type(scores) == 'table' then
			local ids = {}
			for i, v in ipairs(query_set) do
				tinsert(ids, v.id)
			end
			self:setCustom(key, ids, 'zset', scores)
		else
			local ids = {}
			for i, v in ipairs(query_set) do
				tinsert(ids, v.id)
			end
			self:setCustom(key, ids, 'list')
		end
		
		return self
	end;
	
	-- 
	getCustomKey = function (self, key)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)
		
		return custom_key, db:type(custom_key)
	end;

	-- 
	getCustom = function (self, key, atype, start, stop, is_rev)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)
		if not db:exists(custom_key) then
			print(("[Warning] @getCustom - Key %s doesn't exist!"):format(custom_key))
			if not atype or atype == 'string' then return nil
			elseif atype == 'list' then
				return List()
			else
				-- TODO: need to seperate every type
				return {}
			end
		end
		
		-- get the store type in redis
		local store_type = db:type(custom_key)
		if atype then assert(store_type == atype, '[Error] @getCustom - The specified type is not equal the type stored in db.') end
		local store_module = getStoreModule(store_type)
		local ids, scores = store_module.retrieve(custom_key)
		
		if type(ids) == 'table' and (start or stop) then
			ids = ids:slice(start, stop, is_rev)
			if type(scores) == 'table' then
				scores = scores:slice(start, stop, is_rev)
			end
		end
		
		return ids, scores
	end;

	getCustomQuerySet = function (self, key, start, stop, is_rev)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local query_set_ids, scores = self:getCustom(key, nil, start, stop, is_rev)
		if isFalse(query_set_ids) then
			return QuerySet(), nil
		else
			local query_set, nils = getFromRedisPipeline(self, query_set_ids)
			
			if bamboo.config.auto_clear_index_when_get_failed then
				if not isFalse(nils) then
					for _, v in ipairs(nils) do
						self:removeCustomMember(key, v)
					end
				end
			end	

			return query_set, scores
		end
	end;
	
	delCustom = function (self, key)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)
		
		return db:del(custom_key)		
	end;
	
	-- check whether exist custom key
	existCustom = function (self, key)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)
		
		if not db:exists(custom_key) then
			return false
		else 
			return true
		end
	end;
	
	updateCustom = function (self, key, val)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)

		if not db:exists(custom_key) then print('[Warning] @updateCustom - This custom key does not exist.'); return nil end
		local store_type = db:type(custom_key)
		local store_module = getStoreModule(store_type)
		return store_module.update(custom_key, val)
				 
	end;

	removeCustomMember = function (self, key, val)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)

		if not db:exists(custom_key) then print('[Warning] @removeCustomMember - This custom key does not exist.'); return nil end
		local store_type = db:type(custom_key)
		local store_module = getStoreModule(store_type)
		return store_module.remove(custom_key, val)
		
	end;
	
	addCustomMember = function (self, key, val, stype, score)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)
		
		if not db:exists(custom_key) then print('[Warning] @addCustomMember - This custom key does not exist.'); end
		local store_type = db:type(custom_key) ~= 'none' and db:type(custom_key) or stype
		local store_module = getStoreModule(store_type)
		return store_module.add(custom_key, val, score)
		
	end;
	
	hasCustomMember = function (self, key, mem)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)
		
		if not db:exists(custom_key) then print('[Warning] @hasCustomMember - This custom key does not exist.'); return nil end
		local store_type = db:type(custom_key)
		local store_module = getStoreModule(store_type)
		return store_module.has(custom_key, mem)

	end;

	numCustom = function (self, key)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(key, 'string')
		local custom_key = self:isClass() and getCustomKey(self, key) or getCustomIdKey(self, key)

		if not db:exists(custom_key) then return 0 end
		local store_type = db:type(custom_key)
		local store_module = getStoreModule(store_type)
		return store_module.num(custom_key)
	end;
	
	-----------------------------------------------------------------
	-- Cache API
	--- seven APIs
	-- 1. setCache
	-- 2. getCache
	-- 3. delCache
	-- 4. existCache
	-- 5. addCacheMember
	-- 6. removeCacheMember
	-- 7. hasCacheMember
	-- 8. numCache
	-- 9. lifeCache
	-----------------------------------------------------------------
	setCache = function (self, key, vals, orders)
		I_AM_CLASS(self)
		checkType(key, 'string')
		local cache_key = getCacheKey(self, key)
		local cachetype_key = getCachetypeKey(self, key)
		
		if type(vals) == 'string' or type(vals) == 'number' then
			db:set(cache_key, vals)
		else
			-- checkType(vals, 'table')
			local new_vals = {}
			-- if `vals` is a list, insert its element's id into `new_vals`
			-- ignore the uncorrent element
			
			-- elements in `vals` are ordered, but every element itself is not
			-- nessesary containing enough order info.
			-- for number, it contains enough
			-- for others, it doesn't contain enough
			-- so, we use `orders` to specify the order info
			if #vals >= 1 then
				if isValidInstance(vals[1]) then
					-- save instances' id
					for i, v in ipairs(vals) do
						table.insert(new_vals, v.id)
					end
					
					db:set(cachetype_key, 'instance')
				else
					new_vals = vals
					db:set(cachetype_key, 'general')
				end
			end
				
			rdzset.save(cache_key, new_vals, orders)
		end
		
		-- set expiration
		db:expire(cache_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
		db:expire(cachetype_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
		
	end;

	
	getCache = function (self, key, start, stop, is_rev)
		I_AM_CLASS(self)
		checkType(key, 'string')
		local cache_key = getCacheKey(self, key)
		local cachetype_key = getCachetypeKey(self, key)
		
		local cache_data_type = db:type(cache_key)
		local cache_data
		if cache_data_type == 'string' then
			cache_data = db:get(cache_key)
			if isFalse(cache_data) then return nil end
		elseif cache_data_type == 'zset' then
			cache_data = rdzset.retrieve(cache_key)
			if start or stop then
				cache_data = cache_data:slice(start, stop, is_rev)
			end
			if isFalse(cache_data) then return List() end
		end
		
		
		local cachetype = db:get(cachetype_key)
		if cachetype and cachetype == 'instance' then
			-- if cached instance, return instance list
			local cache_objects = getFromRedisPipeline(self, cache_data)
			
			return cache_objects
		else
			-- else return element list directly
			return cache_data
		end
		
		db:expire(cache_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
		db:expire(cachetype_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
		
	end;
	
	delCache = function (self, key)
		I_AM_CLASS(self)
		checkType(key, 'string')
		local cache_key = getCacheKey(self, key)
		local cachetype_key = getCachetypeKey(self, key)

		db:del(cachetype_key)
		return db:del(cache_key)	
		
	end;
	
	-- check whether exist cache key
	existCache = function (self, key)
		I_AM_CLASS(self)
		local cache_key = getCacheKey(self, key)
		
		return db:exists(cache_key)
	end;
	
	-- 
	addCacheMember = function (self, key, val, score)
		I_AM_CLASS(self)
		checkType(key, 'string')
		local cache_key = getCacheKey(self, key)
		local cachetype_key = getCachetypeKey(self, key)

		local store_type = db:type(cache_key)
		
		if store_type == 'zset' then
			if cachetype_key == 'instance' then
				-- `val` is instance
				checkType(val, 'table')
				if isValidInstance(val) then
					rdzset.add(cache_key, val.id, score)
				end
			else
				-- `val` is string or number
				rdzset.add(cache_key, tostring(val), score)
			end
		elseif store_type == 'string' then
			db:set(cache_key, val)
		end
	
		db:expire(cache_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
		db:expire(cachetype_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
		
	end;
	
	removeCacheMember = function (self, key, val)
		I_AM_CLASS(self)
		checkType(key, 'string')
		local cache_key = getCacheKey(self, key)
		local cachetype_key = getCachetypeKey(self, key)

		local store_type = db:type(cache_key)
		
		if store_type == 'zset' then
			if cachetype_key == 'instance' then
				-- `val` is instance
				checkType(val, 'table')
				if isValidInstance(val) then
					rdzset.remove(cache_key, val.id)
				end
			else
				-- `val` is string or number
				rdzset.remove(cache_key, tostring(val))
			end

		elseif store_type == 'string' then
			db:set(cache_key, '')
		end
		
		db:expire(cache_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
		db:expire(cachetype_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
		
	end;
	
	hasCacheMember = function (self, key, mem)
		I_AM_CLASS(self)
		checkType(key, 'string')
		local cache_key = getCacheKey(self, key)
		local cachetype_key = getCachetypeKey(self, key)

		local store_type = db:type(cache_key)
		
		if store_type == 'zset' then
			if cachetype_key == 'instance' then
				-- `val` is instance
				checkType(mem, 'table')
				if isValidInstance(val) then
					return rdzset.has(cache_key, val.id)
				end
			else
				-- `val` is string or number
				return rdzset.has(cache_key, tostring(mem))
			end

		elseif store_type == 'string' then
			return db:get(cache_key) == mem
		end
		
		db:expire(cache_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
		db:expire(cachetype_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
	end;
	
	numCache = function (self, key)
		I_AM_CLASS(self)

		local cache_key = getCacheKey(self, key)
		local cachetype_key = getCachetypeKey(self, key)

		db:expire(cache_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
		db:expire(cachetype_key, bamboo.config.cache_life or bamboo.CACHE_LIFE)
		
		local store_type = db:type(cache_key)
		if store_type == 'zset' then
			return rdzset.num(cache_key)
		elseif store_type == 'string' then
			return 1
		end
	end;
	
	lifeCache = function (self, key)
		I_AM_CLASS(self)
		checkType(key, 'string')
		local cache_key = getCacheKey(self, key)
		
		return db:ttl(cache_key)
	end;
	
	-- delete self instance object
    -- self can be instance or query set
    delById = function (self, ids)
		I_AM_CLASS(self)
		if bamboo.config.use_fake_deletion == true then
			return self:fakeDelById(ids)
		else
			return self:trueDelById(ids)
		end
    end;
    
    fakeDelById = function (self, ids)
    	local idtype = type(ids)
    	if idtype == 'table' then
	    for _, v in ipairs(ids) do
		v = tostring(v)
		fakedelFromRedis(self, v)
		
	    end
	else
	    fakedelFromRedis(self, tostring(ids))			
    	end
    end;
    
    trueDelById = function (self, ids)
    	local idtype = type(ids)
    	if idtype == 'table' then
	    for _, v in ipairs(ids) do
		v = tostring(v)
		delFromRedis(self, v)
		
	    end
	else
	    delFromRedis(self, tostring(ids))			
    	end
    end;
    
	
	
	-----------------------------------------------------------------
	-- validate form parameters by model defination
	-- usually, params = Form:parse(req)
	-- 
	validate = function (self, params)
		I_AM_CLASS(self)
		checkType(params, 'table')
		local fields = self.__fields
		local err_msgs = {}
		local is_valid = true
		for k, v in pairs(fields) do
			local ret, err_msg = v:validate(params[k], k)
			if not ret then 
				is_valid = false
				for _, msg in ipairs(err_msg) do
					table.insert(err_msgs, msg)
				end
			end
		end
		return is_valid, err_msgs
	end;
	
	
	
    --------------------------------------------------------------------
    -- Instance Functions
    --------------------------------------------------------------------
    -- save instance's normal field
    -- before save, the instance has no id
    save = function (self, params)
		I_AM_INSTANCE(self)

		local new_case = true
		-- here, we separate the new create case and update case
		-- if backwards to Model, the __indexfd is 'id'
		local indexfd = self.__indexfd
		assert(type(indexfd) == 'string', "[Error] the __indexfd should be string.")

		-- if self has id attribute, it is an instance saved before. use id to separate two cases
		if self.id then new_case = false end

		-- update the lastmodified_time
		self.lastmodified_time = socket.gettime()

		local index_key = getIndexKey(self)
		local replies
		if new_case then
			local countername = getCounterName(self)
			local options = { watch = {countername, index_key}, cas = true, retry = 2 }
			replies = db:transaction(options, function(db)
				-- increase the instance counter
				db:incr(countername)
				self.id = db:get(countername)
				local model_key = getNameIdPattern(self)
				local self, store_kv = processBeforeSave(self, params)
				-- assert(not db:zscore(index_key, self[indexfd]), "[Error] save duplicate to an unique limited field, aborted!")
				if db:zscore(index_key, self[indexfd]) then print("[Warning] save duplicate to an unique limited field, canceled!") end

				db:zadd(index_key, self.id, self[indexfd])
				-- update object hash store key
				db:hmset(model_key, unpack(store_kv))
				
				if bamboo.config.index_hash then 
					mih.index(self,true);--create hash index
				end
			end)
		else
			-- update case
			assert(tonumber(getCounter(self)) >= tonumber(self.id), '[Error] @save - invalid id.')
			-- in processBeforeSave, there is no redis action
			local self, store_kv = processBeforeSave(self, params)
			local model_key = getNameIdPattern(self)

			local options = { watch = {index_key}, cas = true, retry = 2 }
			replies = db:transaction(options, function(db)
            if bamboo.config.index_hash then 
                mih.index(self,false);--update hash index
            end

			local score = db:zscore(index_key, self[indexfd])
			-- assert(score == self.id or score == nil, "[Error] save duplicate to an unique limited field, aborted!")
			if not (score == self.id or score == nil) then print("[Warning] save duplicate to an unique limited field, canceled!") end
			
			-- if modified indexfd, score will be nil, remove the old id-indexfd pair, for later new save indexfd
			if not score then
				db:zremrangebyscore(index_key, self.id, self.id)
			end
			-- update __index score and member
			db:zadd(index_key, self.id, self[indexfd])
			-- update object hash store key
			db:hmset(model_key, unpack(store_kv))
			end)
		end
			
		-- make fulltext indexes
		if isUsingFulltextIndex(self) then
			makeFulltextIndexes(self)
		end
		if isUsingRuleIndex(self) then
			updateIndexByRules(self, 'save', 'query')
			updateIndexByRules(self, 'save', 'sortby')
		end

		return self
    end;
    
    -- partially update function, once one field
	-- can only apply to none foreign field
    update = function (self, field, new_value)
		I_AM_INSTANCE(self)
		checkType(field, 'string')
		assert(type(new_value) == 'string' or type(new_value) == 'number' or type(new_value) == 'nil')
		local fld = self.__fields[field]
		if not fld then print(("[Warning] Field %s doesn't be defined!"):format(field)); return nil end
		assert( not fld.foreign, ("[Error] %s is a foreign field, shouldn't use update function!"):format(field))
		local model_key = getNameIdPattern(self)
		assert(db:exists(model_key), ("[Error] Key %s does't exist! Can't apply update."):format(model_key))

		local indexfd = self.__indexfd

        --old indexfd 
        -- apply to db
	    -- if field is indexed, need to update the __index too
		if field == indexfd then
		    assert(new_value ~= nil, "[Error] Can not delete indexfd field");
        	local index_key = getIndexKey(self)
	    	db:zremrangebyscore(index_key, self.id, self.id)
		   	db:zadd(index_key, self.id, new_value)
	    end
        
		-- update the lua object
		self[field] = new_value
        --hash index
        if bamboo.config.index_hash then 
            mih.index(self,false,field);
        end

        --update object in database
		if new_value == nil then
		    -- could not delete index field
			if field ~= indexfd then
				db:hdel(model_key, field)
			end
		else
		    -- apply to db
			-- if field is indexed, need to update the __index too
			if field == indexfd then
				local index_key = getIndexKey(self)
				db:zremrangebyscore(index_key, self.id, self.id)
				db:zadd(index_key, self.id, new_value)
			end
			
		    db:hset(model_key, field, new_value)
		end
		-- update the lastmodified_time
		self.lastmodified_time = socket.gettime()
		db:hset(model_key, 'lastmodified_time', self.lastmodified_time)
	    
		-- apply to lua object
		self[field] = new_value
		
		-- if fulltext index
		if fld.fulltext_index and isUsingFulltextIndex(self) then
			makeFulltextIndexes(self)
		end
		if isUsingRuleIndex(self) then
			updateIndexByRules(self, 'update', 'query')
			updateIndexByRules(self, 'update', 'sortby')
		end
		

		return self
    end;
    
    -- get the model's instance counter value
    -- this can be call by Class and Instance
    getCounter = getCounter; 
    
    -- delete self instance object
    -- self can be instance or query set
    fakeDel = function (self)
		-- if self is query set
		if isQuerySet(self) then
			for _, v in ipairs(self) do
				fakedelFromRedis(v)
				v = nil
			end
		else
			fakedelFromRedis(self)
		end
		
		self = nil
    end;
	
	-- delete self instance object
    -- self can be instance or query set
    trueDel = function (self)
		-- if self is query set
		if isQuerySet(self) then
			for _, v in ipairs(self) do
				delFromRedis(v)
				v = nil
			end
		else
			delFromRedis(self)
		end
		
		self = nil
    end;
	
	
	-- delete self instance object
    -- self can be instance or query set
    del = function (self)
		I_AM_INSTANCE_OR_QUERY_SET(self)
		if bamboo.config.use_fake_deletion == true then
			return self:fakeDel()
		else
			return self:trueDel()
		end
    end;

	-- use style: Model_name:restoreDeleted(id)
	restoreDeleted = function (self, id)
		I_AM_CLASS(self)
		return restoreFakeDeletedInstance(self, id)
	end;
	
	-- clear all deleted instance and its foreign relations
	sweepDeleted = function (self)
		local deleted_keys = db:keys('DELETED:*')
		for _, v in ipairs(deleted_keys) do
			-- containing hash structure and foreign zset structure
			db:del(v)
		end
		db:del(dcollector)
	end;

	-----------------------------------------------------------------------------------
	-- Foreign API
	-----------------------------------------------------------------------------------
	---
	-- add a foreign object's id to this foreign field
	-- return self
	addForeign = function (self, field, obj)
		I_AM_INSTANCE(self)
		checkType(field, 'string')
		assert(tonumber(getCounter(self)) >= tonumber(self.id), '[Error] before doing addForeign, you must save this instance.')
		assert(type(obj) == 'table' or type(obj) == 'string', '[Error] "obj" should be table or string.')
		if type(obj) == 'table' then checkType(tonumber(obj.id), 'number') end
		
		local fld = self.__fields[field]
		assert(fld, ("[Error] Field %s doesn't be defined!"):format(field))
		assert( fld.foreign, ("[Error] This field %s is not a foreign field."):format(field))
		assert( fld.st, ("[Error] No store type setting for this foreign field %s."):format(field))
		assert( fld.foreign == 'ANYSTRING' or obj.id, 
			"[Error] This object doesn't contain id, it's not a valid object!")
		assert( fld.foreign == 'ANYSTRING' or fld.foreign == 'UNFIXED' or fld.foreign == getClassName(obj), 
			("[Error] This foreign field '%s' can't accept the instance of model '%s'."):format(
			field, getClassName(obj) or tostring(obj)))
		
		local new_id
		if fld.foreign == 'ANYSTRING' then
			checkType(obj, 'string')
			new_id = obj
		elseif fld.foreign == 'UNFIXED' then
			new_id = getNameIdPattern(obj)
		else
			new_id = obj.id
		end
		
		local model_key = getNameIdPattern(self)
		if fld.st == 'ONE' then
			-- record in db
			db:hset(model_key, field, new_id)
			-- ONE foreign value can be get by 'get' series functions
			self[field] = new_id

		else
			local key = getFieldPattern(self, field)
			local store_module = getStoreModule(fld.st)
			store_module.add(key, new_id, fld.fifolen or socket.gettime())
			-- in zset, the newest member has the higher score
			-- but use getForeign, we retrieve them from high to low, so newest is at left of result
		end
		
		-- update the lastmodified_time
		self.lastmodified_time = socket.gettime()
		db:hset(model_key, 'lastmodified_time', self.lastmodified_time)
		return self
	end;
	
	-- 
	-- 
	-- 
	getForeign = function (self, field, start, stop, is_rev)
		I_AM_INSTANCE(self)
		checkType(field, 'string')
		local fld = self.__fields[field]
		assert(fld, ("[Error] Field %s doesn't be defined!"):format(field))
		assert(fld.foreign, ("[Error] This field %s is not a foreign field."):format(field))
		assert(fld.st, ("[Error] No store type setting for this foreign field %s."):format(field))
				
		if fld.st == 'ONE' then
			if isFalse(self[field]) then return nil end

			local model_key = getNameIdPattern(self)
			if fld.foreign == 'ANYSTRING' then
				-- return string directly
				return self[field]
			else
				local link_model, linked_id
				if fld.foreign == 'UNFIXED' then
					link_model, linked_id = seperateModelAndId(self[field])
				else
					-- normal case
					link_model = getModelByName(fld.foreign)
					linked_id = self[field]
				end	
				
				local obj = link_model:getById (linked_id)
				if not isValidInstance(obj) then
					print('[Warning] invalid ONE foreign id or object for field: '..field)
					
					if bamboo.config.auto_clear_index_when_get_failed then
						-- clear invalid foreign value
						db:hdel(model_key, field)
						self[field] = nil 
					end
					
					return nil
				else
					return obj
				end
			end
		else
			if isFalse(self[field]) then return QuerySet() end
			
			local key = getFieldPattern(self, field)
		
			local store_module = getStoreModule(fld.st)
			-- scores may be nil
			local list, scores = store_module.retrieve(key)

			if list:isEmpty() then return QuerySet() end
			list = list:slice(start, stop, is_rev)
			if list:isEmpty() then return QuerySet() end
			if not isFalse(scores) then scores = scores:slice(start, stop, is_rev) end
		
			local objs, nils = retrieveObjectsByForeignType(fld.foreign, list, key)

			if bamboo.config.auto_clear_index_when_get_failed then
				-- clear the invalid foreign item value
				if not isFalse(nils) then
					-- each element in nils is the id pattern string, when clear, remove them directly
					for _, v in ipairs(nils) do
						store_module.remove(key, v)
					end
				end
			end
			
			return objs, scores
		end
	end;

	getForeignIds = function (self, field, start, stop, is_rev)
		I_AM_INSTANCE(self)
		checkType(field, 'string')
		local fld = self.__fields[field]
		assert(fld, ("[Error] Field %s doesn't be defined!"):format(field))
		assert(fld.foreign, ("[Error] This field %s is not a foreign field."):format(field))
		assert(fld.st, ("[Error] No store type setting for this foreign field %s."):format(field))
				
		if fld.st == 'ONE' then
			if isFalse(self[field]) then return nil end

			return self[field]

		else
			if isFalse(self[field]) then return List() end
			local key = getFieldPattern(self, field)
			local store_module = getStoreModule(fld.st)
			local list, scores = store_module.retrieve(key)
			if list:isEmpty() then return List() end
			list = list:slice(start, stop, is_rev)
			if list:isEmpty() then return List() end
			if not isFalse(scores) then scores = scores:slice(start, stop, is_rev) end

			return list, scores
		end

	end;    
	
	-- rearrange the foreign index by input list
	rearrangeForeign = function (self, field, inlist)
		I_AM_INSTANCE(self)
		assert(type(field) == 'string' and type(inlist) == 'table', '[Error] @ rearrangeForeign - parameters type error.' )
		local fld = self.__fields[field]
		assert(fld, ("[Error] Field %s doesn't be defined!"):format(field))
		assert(fld.foreign, ("[Error] This field %s is not a foreign field."):format(field))
		assert(fld.st, ("[Error] No store type setting for this foreign field %s."):format(field))

		local new_orders = {}
		local orig_orders = self:getForeignIds(field)
		local orig_len = #orig_orders
		local rorig_orders = {}
		-- make reverse hash for all ids
		for i, v in ipairs(orig_orders) do
			rorig_orders[tostring(v)] = i
		end
		-- retrieve valid elements in inlist
		for i, elem in ipairs(inlist) do
			local pos = rorig_orders[elem]  -- orig_orders:find(tostring(elem))
			if pos then
				tinsert(new_orders, elem)
				-- remove the original element
				orig_orders[pos] = nil
			end
		end
		-- append the rest elements in foreign to the end of new_orders
		for i = 1, orig_len do
			if orig_orders[i] ~= nil then
				tinsert(new_orders, v)
			end
		end
		
		local key = getFieldPattern(self, field)
		-- override the original foreign zset value
		rdzset.save(key, new_orders)
		
		return self
	end;
	
	-- delelte a foreign member
	-- obj can be instance object, also can be object's id, also can be anystring.
	delForeign = function (self, field, obj)
		I_AM_INSTANCE(self)
		checkType(field, 'string')
		local fld = self.__fields[field]
		assert(not isFalse(obj), "[Error] @delForeign. param obj must not be nil.")
		assert(fld, ("[Error] Field %s doesn't be defined!"):format(field))
		assert(fld.foreign, ("[Error] This field %s is not a foreign field."):format(field))
		assert(fld.st, ("[Error] No store type setting for this foreign field %s."):format(field))
		--assert( fld.foreign == 'ANYSTRING' or obj.id, "[Error] This object doesn't contain id, it's not a valid object!")
		assert(fld.foreign == 'ANYSTRING' 
			or fld.foreign == 'UNFIXED' 
			or (type(obj) == 'table' and fld.foreign == getClassName(obj)), 
			("[Error] This foreign field '%s' can't accept the instance of model '%s'."):format(field, getClassName(obj) or tostring(obj)))

		-- if self[field] is nil, it must be wrong somewhere
		if isFalse(self[field]) then return nil end
		
		local new_id
		if isNumOrStr(obj) then
			-- obj is id or anystring
			new_id = tostring(obj)
		else
			checkType(obj, 'table')
			if fld.foreign == 'UNFIXED' then
				new_id = getNameIdPattern(obj)
			else 
				new_id = tostring(obj.id)
			end
		end
		
		local model_key = getNameIdPattern(self)
		if fld.st == 'ONE' then
			-- we must check the equality of self[filed] and new_id before perform delete action
			if self[field] == new_id then
				-- maybe here is rude
				db:hdel(model_key, field)
				self[field] = nil
			end
		else
			local key = getFieldPattern(self, field)
			local store_module = getStoreModule(fld.st)
			store_module.remove(key, new_id)
		end
	
		-- update the lastmodified_time
		self.lastmodified_time = socket.gettime()
		db:hset(model_key, 'lastmodified_time', self.lastmodified_time)
		return self
	end;
	
	clearForeign = function (self, field)
		I_AM_INSTANCE(self)
		checkType(field, 'string')
		local fld = self.__fields[field]
		assert(fld, ("[Error] Field %s doesn't be defined!"):format(field))
		assert(fld.foreign, ("[Error] This field %s is not a foreign field."):format(field))
		assert(fld.st, ("[Error] No store type setting for this foreign field %s."):format(field))


		local model_key = getNameIdPattern(self)
		if fld.st == 'ONE' then
			-- maybe here is rude
			db:hdel(model_key, field)
		else
			local key = getFieldPattern(self, field)		
			-- delete the foreign key
			db:del(key)
		end
		
		-- update the lastmodified_time
		self.lastmodified_time = socket.gettime()
		db:hset(model_key, 'lastmodified_time', self.lastmodified_time)
		return self		
	end;

	deepClearForeign = function (self, field)
		I_AM_INSTANCE(self)
		checkType(field, 'string')
		local fld = self.__fields[field]
		assert(fld, ("[Error] Field %s doesn't be defined!"):format(field))
		assert(fld.foreign, ("[Error] This field %s is not a foreign field."):format(field))
		assert(fld.st, ("[Error] No store type setting for this foreign field %s."):format(field))

		-- delete the foreign objects first
		local fobjs = self:getForeign(field)
		if fobjs then fobjs:del() end

		local model_key = getNameIdPattern(self)
		if fld.st == 'ONE' then
			-- maybe here is rude
			db:hdel(model_key, field)
		else
			local key = getFieldPattern(self, field)		
			-- delete the foreign key
			db:del(key)
		end
		
		-- update the lastmodified_time
		self.lastmodified_time = socket.gettime()
		db:hset(model_key, 'lastmodified_time', self.lastmodified_time)
		return self		
	end;

	-- check whether some obj is already in foreign list
	-- instance:inForeign('some_field', obj)
	hasForeign = function (self, field, obj)
		I_AM_INSTANCE(self)
		checkType(field, 'string')
		local fld = self.__fields[field]
		assert(fld, ("[Error] Field %s doesn't be defined!"):format(field))
		assert(fld.foreign, ("[Error] This field %s is not a foreign field."):format(field))
		assert( fld.st, ("[Error] No store type setting for this foreign field %s."):format(field))
		assert(fld.foreign == 'ANYSTRING' or obj.id, "[Error] This object doesn't contain id, it's not a valid object!")
		assert(fld.foreign == 'ANYSTRING' or fld.foreign == 'UNFIXED' or fld.foreign == getClassName(obj),
			   ("[Error] The foreign model (%s) of this field %s doesn't equal the object's model %s."):format(fld.foreign, field, getClassName(obj) or ''))
		if isFalse(self[field]) then return nil end

		local new_id
		if isNumOrStr(obj) then
			-- obj is id or anystring
			new_id = tostring(obj)
		else
			checkType(obj, 'table')
			if fld.foreign == 'UNFIXED' then
				new_id = getNameIdPattern(self)
			else
				new_id = tostring(obj.id)
			end
		end

		if fld.st == "ONE" then
			return self[field] == new_id
		else
			local key = getFieldPattern(self, field)
			local store_module = getStoreModule(fld.st)
			return store_module.has(key, new_id)
		end 
	
		return false
	end;

	-- return the number of elements in the foreign list
	-- @param field:  field of that foreign model
	numForeign = function (self, field)
		I_AM_INSTANCE(self)
		checkType(field, 'string')
		local fld = self.__fields[field]
		assert(fld, ("[Error] Field %s doesn't be defined!"):format(field))
		assert( fld.foreign, ("[Error] This field %s is not a foreign field."):format(field))
		assert( fld.st, ("[Error] No store type setting for this foreign field %s."):format(field))
		-- if foreign field link is now null
		if isFalse(self[field]) then return 0 end
		
		if fld.st == 'ONE' then
			-- the ONE foreign field has only 1 element
			return 1
		else
			local key = getFieldPattern(self, field)
			local store_module = getStoreModule(fld.st)
			return store_module.num(key)
		end
	end;

	-- check this class/object has a foreign key
	-- @param field:  field of that foreign model
	hasForeignKey = function (self, field)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(field, 'string')
		local fld = self.__fields[field]
		if fld and fld.foreign then return true
		else return false
		end
		
	end;

	--- return the class name of an instance
	classname = function (self)
		return getClassName(self)
	end;

	-- do sort on query set by some field
	sortBy = function (self, field, direction, sort_func, ...)
		I_AM_QUERY_SET(self)

		local query_set_meta
		local query_str_iden
		local sortby_args
		local sortby_str_iden
		local can_use_sortby_rule = true
		
		local is_using_rule_index = isUsingRuleIndex()
		if is_using_rule_index then
			query_set_meta = getmetatable(self)
			print('in sortby');ptable(query_set_meta)
			query_str_iden = query_set_meta['query_str_iden']
			if query_str_iden == false then
				-- for rule can't fit
				can_use_sortby_rule = false
			else
				-- for general rule or 'all()' rule
				query_str_iden = query_str_iden or ''
			end
			sortby_args = {field, direction, sort_func, ...}
			ptable(sortby_args)
			sortby_str_iden = compressSortByArgs(query_str_iden, sortby_args)
		end
		
		local direction = direction or 'asc'
		local byfield = field
		local sort_func = sort_func or function (a, b)
			local af = a[byfield] 
			local bf = b[byfield]
			if af and bf then
				if direction == 'asc' then
					return af < bf
				elseif direction == 'desc' then
					return af > bf
				end
			else
				return nil
			end
		end
		
		table.sort(self, sort_func)
		
		-- secondary sort
		local field2, dir2, sort_func2 = ...
		if field2 then
			checkType(field2, 'string')

			-- divide to parts
			local work_t = {{self[1]}, }
			for i = 2, #self do
				if self[i-1][field] == self[i][field] then
					-- insert to the last table element of the list
					table.insert(work_t[#work_t], self[i])
				else
					work_t[#work_t + 1] = {self[i]}
				end
			end

			-- sort each part
			local result = {}
			byfield = field2
			direction = dir2 or 'asc'
			sort_func = sort_func2 or sort_func
			for i, val in ipairs(work_t) do
				table.sort(val, sort_func)
				table.insert(result, val)
			end

			-- flatten to one rank table
			local flat = QuerySet()
			for i, val in ipairs(result) do
				for j, v in ipairs(val) do
					table.insert(flat, v)
				end
			end

			self = flat
		end

		if is_using_rule_index and can_use_sortby_rule then
			local id_list = {}
			for _, v in ipairs(self) do
				tinsert(id_list, v.id)
			end
			local model = self[1]:getClass()
			-- add to index
			addIndexToManager(model, sortby_str_iden, id_list, 'sortby')
		end

		return self		
	end;
	
	getRuleIndexIds = function (self, query_args, sortby_args, start, stop, is_rev)
		I_AM_CLASS(self)
		assert(type(query_args) == 'table' or type(query_args) == 'function')
		assert(type(sortby_args) == 'table')
		
		local query_str_iden = compressQueryArgs(query_args)
		local sortby_str_iden = compressSortByArgs(query_str_iden, sortby_args)
		
		local id_list = getIndexFromManager(self, sortby_str_iden, nil, 'sortby')
		if id_list then
			if #id_list == 0 then
				return id_list
			else
				return id_list:slice(start, stop, is_rev)
			end
		else
			return List()
		end
		
	end;
	
	getRuleIndexQuerySet = function (self, query_args, sortby_args, start, stop, is_rev)
		I_AM_CLASS(self)
		local id_list = self:getRuleIndexIds(query_args, sortby_args, start, stop, is_rev)
		
		if #id_list == 0 then
			return QuerySet()
		else
			return getFromRedisPipeline(self, id_list)
		end
	
	end;
	
	
	addToCacheAndSortBy = function (self, cache_key, field, sort_func)
		I_AM_INSTANCE(self)
		checkType(cache_key, field, 'string', 'string')
		
		--DEBUG(cache_key)
		--DEBUG('entering addToCacheAndSortBy')
		local cache_saved_key = getCacheKey(self, cache_key)
		if not db:exists(cache_saved_key) then 
			print('[WARNING] The cache is missing or expired.')
			return nil
		end
		
		local cached_ids = db:zrange(cache_saved_key, 0, -1)
		local head = db:hget(getNameIdPattern2(self, cached_ids[1]), field)
		local tail = db:hget(getNameIdPattern2(self, cached_ids[#cached_ids]), field)
		assert(head and tail, "[Error] @addToCacheAndSortBy. the object referring to head or tail of cache list may be deleted, please check.")
		--DEBUG(head, tail)
		local order_type = 'asc'
		local field_value, stop_id
		local insert_position = 0
		
		if head > tail then order_type = 'desc' end
		-- should always keep `a` and `b` have the same type
		local sort_func = sort_func or function (a, b)
			if order_type == 'asc' then
				return a > b
			elseif order_type == 'desc' then
				return a < b
			end
		end
		
		--DEBUG(order_type)
		-- find the inserting position
		-- FIXME: use 2-part searching method is better
		for i, id in ipairs(cached_ids) do
			field_value = db:hget(getNameIdPattern2(self, id), field)
			if sort_func(field_value, self[field]) then
				stop_id = db:hget(getNameIdPattern2(self, id), 'id')
				insert_position = i
				break
			end
		end
		--DEBUG(insert_position)

		local new_score
		if insert_position == 0 then 
			-- means till the end, all element is smaller than self.field
			-- insert_position = #cached_ids
			-- the last element's score + 1
			local end_score = db:zrange(cache_saved_key, -1, -1, 'withscores')[1][2]
			new_score = end_score + 1
		
		elseif insert_position == 1 then
			-- get the half of the first element
			local stop_score = db:zscore(cache_saved_key, stop_id)
			new_score = tonumber(stop_score) / 2
		elseif insert_position > 1 then
			-- get the middle value of the left and right neighbours
			local stop_score = db:zscore(cache_saved_key, stop_id)
			local stopprev_rank = db:zrank(cache_saved_key, stop_id) - 1
			local stopprev_score = db:zrange(cache_saved_key, stopprev_rank, stopprev_rank, 'withscores')[1][2]
			new_score = tonumber(stop_score + stopprev_score) / 2
		
		end
		
		--DEBUG(new_score)
		-- add new element to cache
		db:zadd(cache_saved_key, new_score, self.id)
			
		
		return self
	end;

	
	--------------------------------------------------------------------------
	-- Dynamic Field API
	--------------------------------------------------------------------------
	
	-- called by model
	addDynamicField = function (self, field_name, field_dt)
		I_AM_CLASS(self)
		checkType(field_name, field_dt, 'string', 'table')
		
		
		local fields = self.__fields
		if not fields then print('[Warning] This model has no __fields.'); return nil end
		-- if already exist, can not override it
		-- ensure the added is new field
		if not fields[field_name] then
			fields[field_name] = field_dt
			-- record to db
			local key = getDynamicFieldKey(self, field_name)
			for k, v in pairs(field_dt) do
				db:hset(key, k, serialize(v))
			end
			-- add to dynamic field index list
			db:rpush(getDynamicFieldIndex(self), field_name)
		end
		
	end;
	
	hasDynamicField = function (self)
		I_AM_CLASS(self)
		local dfindex = getDynamicFieldIndex(self)
		if db:exists(dfindex) and db:llen(dfindex) > 0 then
			return true
		else
			return false
		end
	end;
	
	delDynamicField = function (self, field_name)
		I_AM_CLASS(self)
		checkType(field_name, 'string')
		local dfindex = getDynamicFieldIndex(self)
		local dfield = getDynamicFieldKey(self, field_name)
		-- get field description table
		db:del(dfield)
		db:lrem(dfindex, 0, field_name)
		self.__fields[field_name] = nil
		
		return self
	end;

	importDynamicFields = function (self)
		I_AM_CLASS(self)
		local dfindex = getDynamicFieldIndex(self)
		local dfields_list = db:lrange(dfindex, 0, -1)
		
		for _, field_name in ipairs(dfields_list) do
			local dfield = getDynamicFieldKey(self, field_name)
			-- get field description table
			local data = db:hgetall(dfield)
			-- add new field to __fields
			self.__fields[field_name] = data
		end
		
		return self
	end;

	querySetIds = function (self)
		I_AM_QUERY_SET(self)
		local ids = List()
		for _, v in ipairs(self) do
			ids:append(v.id)
		end
		return ids
	end;
	
--	pipeline = function (self, func)
--		I_AM_QUERY_SET(self)
--		local ret = db:pipeline(function (db)
--			for _, v in ipairs(self) do
--				func(v)
--			end
--		end)
--		-- at this abstract level, pipeline's returned value is not stable
--		return self
--	end;
	
	-- for fulltext index API
	fulltextSearch = function (self, ask_str, n)
		I_AM_CLASS(self)
		local tags = wordSegmentOnFtIndex(self, ask_str)
		return searchOnFulltextIndexes(self, tags, n)
	end;

	-- for fulltext index API
	fulltextSearchByWord = function (self, word, n)
		I_AM_CLASS(self)
		return searchOnFulltextIndexes(self, {word}, n)
	end;

	getFDT = function (self, field)
		I_AM_CLASS_OR_INSTANCE(self)
		checkType(field, 'string')
		
		return self.__fields[field]
		
	end;

}

local QuerySetMeta = setProto({__spectype='QuerySet'}, Model)
QuerySet = function (list)
	local list = List(list)
	-- create a query set	
	-- add it to fit the check of isClass function
--	if not getmetatable(QuerySetMeta) then
--		QuerySetMeta = setProto(QuerySetMeta, Model)
--	end
	local query_set = setProto(list, QuerySetMeta)
	
	return query_set
end

_G['QuerySet'] = QuerySet

return Model
