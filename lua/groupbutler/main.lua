local config = require "groupbutler.config"
local methods = require "telegram-bot-api.methods"
local utilities = require "groupbutler.utilities"
local log = require "groupbutler.logging"
local redis = require "resty.redis"
local plugins = require "groupbutler.plugins"
local Message = require "groupbutler.message"
local User = require "groupbutler.user"
local Chat = require "groupbutler.chat"
local ChatMember = require "groupbutler.chatmember"
local Storage = require("groupbutler.storage."..config.storage)
local locale = require "groupbutler.languages"
local api_err = require "groupbutler.api_errors"

local _M = {}

local get_me = {}

function _M:new(update_obj)
	setmetatable(update_obj, {__index = self})

	local tg_token = config.telegram.token
	update_obj.api = methods:new(tg_token)
	if not get_me[tg_token] then
		get_me[tg_token] = update_obj.api:get_me()
	end
	update_obj.bot = get_me[tg_token]

	update_obj.red = redis:new()
	local ok, err = update_obj.red:connect(config.redis.host, config.redis.port)
	if not ok then
		log.error("Redis connection failed: {err}", {err=err})
		return nil, err
	end
	update_obj.red:select(config.redis.db)
	update_obj.db = Storage:new(update_obj.red)
	update_obj.i18n = locale:new()
	update_obj.api_err = api_err:new(update_obj)
	update_obj.u = utilities:new(update_obj)

	return update_obj
end

local function inject_message_methods(message, update)
	if message.from then
		message.from = {
			user = message.from,
			chat = message.chat,
		}
	end
	Message:new(message, update)
	if message.from then
		if message.from.user then -- Sender is empty for messages sent to channels
			User:new(message.from.user, update):cache()
		end
		if message.from.chat then
			Chat:new(message.chat, update)--:cache()
		end
		if message.from.user and message.from.chat then
			ChatMember:new(message.from, update)--:cache()
		end
	end
	if message.forward_from then
		User:new(message.forward_from, update):cache()
	end
	if message.new_chat_members then
		for k,v in pairs(message.new_chat_members) do
			message.new_chat_members[k] = {
				user = v,
				chat = message.chat,
			}
			User:new(message.new_chat_members[k].user, update)
			Chat:new(message.new_chat_members[k].chat, update)
			ChatMember:new(message.new_chat_members[k], update):cache()
		end
	end
end

local function add_message_methods(object, update)
	local message_objects = {
		"message", --[["edited_message",]] "channel_post", -- Possible messages inside updates
		"reply_to_message", "pinned_message",        -- Possible messages inside messages
	}
	for _, message in pairs(message_objects) do
		if type(object[message]) == "table" then
			inject_message_methods(object[message], update)
			add_message_methods(object[message], update)
		end
	end
end

local function add_methods(update)
	add_message_methods(update, update)
end

local function collect_stats(self)
	local msg = self.message
	-- local red = self.red
	local u = self.u
	local now = os.time(os.date("*t"))
	-- if msg.from.chat.type ~= 'private' and msg.from.chat.type ~= 'inline' and msg.from.user then
	-- 	red:hset('chat:'..msg.from.chat.id..':userlast', msg.from.user.id, now) --last message for each user
	-- 	red:hset('bot:chats:latsmsg', msg.from.chat.id, now) --last message in the group
	-- end
	u:metric_incr("messages_processed_count")
	u:metric_set("message_timestamp_distance_sec", now - msg.date)
end

local function match_triggers(self, triggers)
	local bot = self.bot
	local text = self.message.text

	if not text or not triggers then return nil end
		text = text:gsub('^(/[%w_]+)@'..bot.username, '%1')
		for _, trigger in pairs(triggers) do
			local matches = { string.match(text, trigger) }
			if next(matches) then
				return matches, trigger
			end
		end
	return nil
end

local function on_msg_receive(self, callback) -- The fn run whenever a message is received.
	local msg = self.message
	local bot = self.bot
	local u = self.u
	local red = self.red
	local api = self.api
	local i18n = self.i18n
	-- u:dump(msg)

	if not msg then
		log.error("Message missing")
		return
	end

	-- Do not process old updates
	local now = os.time(os.date("*t"))
	if msg.date < now - config.bot_settings.old_update then
		log.warn('Cập nhật cũ bị bỏ qua: {time} {diff}', {time=os.date('%H:%M:%S', msg.date), diff=now-msg.date})
		u:metric_incr("messages_skipped")
		return true
	end

	-- Set chat language
	i18n:setLanguage(red:get('lang:'..msg.from.chat.id))

	-- Do not process messages from normal groups
	if msg.from.chat.type == 'group' then
		api:sendMessage(msg.from.chat.id, i18n([[Xin chào tất cả mọi người!
Tên tôi là %s và tôi là một bot được tạo ra để trợ giúp các quản trị viên trong công việc khó khăn của họ.
Rất tiếc là tôi không thể làm việc trong các nhóm bình thường. Nếu bạn cần tôi, vui lòng yêu cầu người tạo chuyển nhóm này thành siêu nhóm và sau đó thêm tôi lại.
]]):format(bot.first_name))
		api:leaveChat(msg.from.chat.id)
		if config.bot_settings.stream_commands then
			log.info('Bot đã được thêm vào một nhóm bình thường {by_name} [{from_id}] -> [{chat_id}]',
					{
						by_name=msg.from.user.first_name,
						from_id=msg.from.user.id,
						chat_id=msg.from.chat.id,
					})
		end
		return true
	end

	collect_stats(self)

	for i=1, #plugins do
		if plugins[i].on_message then
			local plugin_obj = plugins[i]:new(self)
			local onm_success, continue = pcall(plugin_obj.on_message, plugin_obj)
			if not onm_success then
				log.error('An #error occurred (preprocess).\n{err}\n{lang}\n{text}', {
					err = tostring(continue),
					lang = i18n:getLanguage(),
					text = msg.text,
				})
			end
			if not continue then
				return true
			end
		end
	end

	for i=1, #plugins do
		if plugins[i].triggers then
			local blocks, trigger = match_triggers(self, plugins[i].triggers[callback])
			local plugin_obj = plugins[i]:new(self)

			if blocks then
				-- init agroup if the bot wasn't aware to be in
				if  msg.from.chat.id < 0
				and msg.from.chat.type ~= 'inline'
				and red:exists('chat:'..msg.from.chat.id..':settings') == 0
				and not msg.service then
				u:initGroup(msg.from.chat)
				end

				-- print some info in the terminal
				if config.bot_settings.stream_commands then
					log.info('{trigger} {from_name} [{from_id}] -> [{chat_id}]',
						{
							trigger=trigger,
							from_name=msg.from.user.first_name,
							from_id=msg.from.user.id,
							chat_id=msg.from.chat.id,
						})
				end

				-- execute the main function of the plugin triggered
				local success, result = xpcall(
					(function()
						return plugin_obj[callback](plugin_obj, blocks)
					end), debug.traceback)

				if not success then --if a bug happens
					if config.bot_settings.notify_bug then
					msg:send_reply(i18n("🐞 Sorry, a *bug* occurred"), "Markdown")
					end
					log.error('An #error occurred.\n{result}\n{lang}\n{text}', {
						result=tostring(result),
						lang=i18n:getLanguage(),
						text=msg.text})
					return false
				end
				if not result then -- Stop processing plugins when a triggered plugin does not return true
					return true
				end
			end
		end
	end
	return true
end

function _M:process()
	local u = self.u
	local bot = self.bot

	local start_time = u:time_hires()
	u:metric_incr("messages_count")

	local function_key

	if self.message or self.edited_message then

		function_key = 'onTextMessage'

		if self.edited_message then
			self.edited_message.edited = true
			self.edited_message.original_date = self.edited_message.date
			self.edited_message.date = self.edited_message.edit_date
			function_key = 'onEditedMessage'
		end

		self.message = self.message or self.edited_message -- TODO: undo this

		local service_messages = {
			"left_chat_member", "new_chat_member", "new_chat_photo", "delete_chat_photo", "group_chat_created",
			"supergroup_chat_created", "channel_chat_created", "migrate_to_chat_id", "migrate_from_chat_id",
			"new_chat_title", "pinned_message",
		}
		for _, v in pairs(service_messages) do
			if type(self.message[v]) == "table" then
				self.message.service = true
				self.message.text = "###"..v
				if self.message[v].id == bot.id then
					self.message.text = self.message.text..":bot"
				end
			end
		end

		if self.message.forward_from_chat then
			if self.message.forward_from_chat.type == 'channel' then
				self.message.spam = 'forwards'
			end
		end
		if self.message.caption then
			local caption_lower = self.message.caption:lower()
			if caption_lower:match('telegram%.me') or caption_lower:match('telegram%.dog') or caption_lower:match('t%.me') then
				self.message.spam = 'links'
			end
		end
		if self.message.entities then
			for _, entity in pairs(self.message.entities) do
				if entity.type == 'text_mention' then
					self.message.mention_id = entity.user.id
				end
				if entity.type == 'url' or entity.type == 'text_link' then
					local text_lower = self.message.text or self.message.caption
					text_lower = entity.url and text_lower..entity.url or text_lower
					text_lower = text_lower:lower()
					if text_lower:match('telegram%.me')
					or text_lower:match('telegram%.dog')
					or text_lower:match('t%.me') then
						self.message.spam = 'links'
					end
				end
			end
		end
		if self.message.reply_to_message then
			self.message.reply = self.message.reply_to_message
			if self.message.reply.caption then
				self.message.reply.text = self.message.reply.caption
			end
		end
	elseif self.callback_query then
		self.message = self.callback_query
		self.message.cb = true
		self.message.text = '###cb:'..self.message.data
		if self.message.message then
			self.message.original_text = self.message.message.text
			self.message.original_date = self.message.message.date
			self.message.message_id = self.message.message.message_id
			self.message.chat = self.message.message.chat
		else --when the inline keyboard is sent via the inline mode
			self.message.chat = {
				type = 'inline',
				id = self.message.from.user.id,
				title = self.message.from.user.first_name
			}
			self.message.message_id = self.message.inline_message_id
		end
		self.message.date = os.time()
		self.message.cb_id = self.message.id
		self.message.message = nil
		self.message.target_id = self.message.data:match('(-%d+)$') --callback datas often ship IDs
		function_key = 'onCallbackQuery'
	else
		--function_key = 'onUnknownType'
		log.warn("Unknown update type")
		return false
	end

	if not self.message.text then self.message.text = self.message.caption or '' end

	add_methods(self)

	local retval = on_msg_receive(self, function_key)
	u:metric_set("msg_request_duration_sec", u:time_hires() - start_time)
	-- print(self.db:get_reused_times())
	self.db:set_keepalive()
	return retval
end

return _M
