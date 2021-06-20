local config = require "groupbutler.config"
local ApiUtil = require("telegram-bot-api.utilities")
local log = require "groupbutler.logging"
local null = require "groupbutler.null"
local User = require("groupbutler.user")
local ChatMember = require("groupbutler.chatmember")
local Util = require("groupbutler.util")

local http, HTTPS, ltn12, time_hires, sleep
if ngx then
	http = require "resty.http"
	time_hires = ngx.now
	sleep = ngx.sleep
else
	HTTPS = require "ssl.https"
	ltn12 = require "ltn12"
	local socket = require "socket"
	time_hires = socket.gettime
	sleep = socket.sleep
end

local _M = {} -- Functions shared among plugins

local function p(self)
	return getmetatable(self)._private
end

function _M:new(private)
	local obj = {}
	assert(private.api, "Utilities: Missing private.api")
	assert(private.api_err, "Utilities: Missing private.api_err")
	assert(private.bot, "Utilities: Missing private.bot")
	assert(private.db, "Utilities: Missing private.db")
	assert(private.i18n, "Utilities: Missing private.i18n")
	assert(private.red, "Utilities: Missing private.red")
	setmetatable(obj, {
		__index = self,
		_private = private,
	})
	return obj
end

-- Strings

-- Escape markdown for Telegram. This function makes non-clickable usernames,
-- hashtags, commands, links and emails, if only_markup flag isn't setted.
function string:escape(only_markup)
	if not only_markup then
		-- insert word joiner
		self = self:gsub('([@#/.])(%w)', '%1\226\129\160%2')
	end
	return self:gsub('[*_`[]', '\\%0')
end

function string:escape_html()
	self = self:gsub('&', '&amp;')
	self = self:gsub('"', '&quot;')
	self = self:gsub('<', '&lt;'):gsub('>', '&gt;')
	return self
end

-- Remove specified formating or all markdown. This function useful for putting names into message.
-- It seems not possible send arbitrary text via markdown.
function string:escape_hard(ft)
	if ft == 'bold' then
		return self:gsub('%*', '')
	elseif ft == 'italic' then
		return self:gsub('_', '')
	elseif ft == 'fixed' then
		return self:gsub('`', '')
	elseif ft == 'link' then
		return self:gsub(']', '')
	else
		return self:gsub('[*_`[%]]', '')
	end
end

function string:escape_magic()
	self = self:gsub('%%', '%%%%')
	self = self:gsub('%-', '%%-')
	self = self:gsub('%?', '%%?')

	return self
end

-- Perform substitution of placeholders in the text according given the message.
-- The second argument can be the flag to avoid the escape, if it's set, the
-- markdown escape isn't performed. In any case the following arguments are
-- considered as the sequence of strings - names of placeholders. If
-- placeholders to replacing are specified, this function processes only them,
-- otherwise it processes all available placeholders.
function _M:replaceholders(str, msg, ...)
	if msg.new_chat_member then
		msg.from.user = msg.new_chat_member
	elseif msg.left_chat_member then
		msg.from.user = msg.left_chat_member
	end

	msg.from.chat.title = msg.from.chat.title and msg.from.chat.title or '-'

	local tail_arguments = {...}
	-- check that the second argument is a boolean and true
	local non_escapable = tail_arguments[1] == true

	local replace_map
	if non_escapable then
		replace_map = {
			name = msg.from.user.first_name,
			surname = msg.from.user.last_name and msg.from.user.last_name or '',
			username = msg.from.user.username and '@'..msg.from.user.username or '-',
			id = msg.from.user.id,
			title = msg.from.chat.title,
			rules = self:deeplink_constructor(msg.from.chat.id, "rules"),
		}
		-- remove flag about escaping
		table.remove(tail_arguments, 1)
	else
		replace_map = {
			name = msg.from.user.first_name:escape(),
			surname = msg.from.user.last_name and msg.from.user.last_name:escape() or '',
			username = msg.from.user.username and '@'..msg.from.user.username:escape() or '-',
			userorname = msg.from.user.username and '@'..msg.from.user.username:escape() or msg.from.user.first_name:escape(),
			id = msg.from.user.id,
			title = msg.from.chat.title:escape(),
			rules = self:deeplink_constructor(msg.from.chat.id, "rules"),
		}
	end

	local substitutions = next(tail_arguments) and {} or replace_map
	for _, placeholder in pairs(tail_arguments) do
		substitutions[placeholder] = replace_map[placeholder]
	end

	return str:gsub('$(%w+)', substitutions)
end

function _M:is_superadmin(user_id) -- luacheck: ignore 212
	for i=1, #config.superadmins do
		if tonumber(user_id) == config.superadmins[i] then
			return true
		end
	end
	return false
end

function _M:cache_adminlist(chat)
	local api = p(self).api
	local red = p(self).red
	local db = p(self).db

	local global_lock = "bot:getadmin_lock"
	local chat_lock = "cache:chat:"..chat.id..":getadmin_lock"
	local set = 'cache:chat:'..chat.id..':admins'

	if red:exists(global_lock) == 1
	or red:exists(chat_lock) == 1 then
		while red:exists(set) == 0
		and (red:exists(global_lock) == 1 or red:exists(chat_lock) == 1) do
			sleep(0.1)
		end
	end

	red:setex(global_lock, 5, "")
	log.info('Lưu danh sách quản trị viên cho: {chat_id}', {chat_id=chat.id})
	self:metric_incr("api_getchatadministrators_count")
	local ok, err = api:getChatAdministrators(chat.id)
	if not ok then
		if err.retry_after then
			red:setex(global_lock, err.retry_after, "")
		else
			red:setex(global_lock, 30, "")
		end
		self:metric_incr("api_getchatadministrators_error_count")
		return false, err
	end

	db:cacheAdmins(chat, ok)

	return true, #ok or 0
end

function _M:is_blocked_global(id)
	local red = p(self).red
	return red:sismember('bot:blocked', id) ~= 0
end

local function dump(o)
	local ot = type(o)
	if ot == "table" then
		local s = "{"
		for k,v in pairs(o) do
			if type(k) ~= "number" then k = '"'..k..'"' end
			s = s .."["..k.."] = "..dump(v)..","
		end
		return s .."}"
	end
	return tostring(o)
end

function _M:dump(o) -- luacheck: ignore 212
	print(dump(o))
end

function _M:download_to_file(url, filepath) -- luacheck: ignore 212
	log.info("url để tải xuống: {url}", {url=url})
	if ngx then
		local httpc = http.new()
		local ok, err = httpc:request_uri(url)

		if not ok or ok.status ~= 200 then
			return nil, err
		end
		local file = io.open(filepath, "w+")
		file:write(ok.body)
		file:close()
		return filepath, ok.status
	else
		local respbody = {}
		local options = {
			url = url,
			sink = ltn12.sink.table(respbody),
			redirect = true
		}
		-- nil, code, headers, status
		options.redirect = false
		local response = {HTTPS.request(options)}
		local code = response[2]
		-- local headers = response[3] -- unused variables
		-- local status = response[4] -- unused variables
		if code ~= 200 then return false, code end
		log.info("Đã lưu vào: {path}", {path=filepath})
		local file = io.open(filepath, "w+")
		file:write(table.concat(respbody))
		file:close()
		return filepath, code
	end
end

function _M:deeplink_constructor(chat_id, what)
	local bot = p(self).bot
	return 'https://telegram.me/'..bot.username..'?start='..chat_id..'_'..what
end

function _M:get_date(timestamp) -- luacheck: ignore 212
	if not timestamp then
		timestamp = os.time()
	end
	return os.date('%d/%m/%y', timestamp)
end

function _M:reply_markup_from_text(text) -- luacheck: ignore 212
	local clean_text = text
	local n = 0
	local reply_markup = ApiUtil.InlineKeyboardMarkup:new()
	for label, url in text:gmatch("{{(.-)}{(.-)}}") do
		clean_text = clean_text:gsub('{{'..label:escape_magic()..'}{'..url:escape_magic()..'}}', '')
		if label and url and n < 3 then
			reply_markup:row({text = label, url = url})
		end
		n = n + 1
	end
	if not next(reply_markup.inline_keyboard) then reply_markup = nil end

	return reply_markup, clean_text
end

function _M:demote(chat_id, user_id)
	local red = p(self).red
	chat_id, user_id = tonumber(chat_id), tonumber(user_id)

	red:del(('chat:%d:mod:%d'):format(chat_id, user_id))
	local removed = red:srem('chat:'..chat_id..':mods', user_id)

	return removed == 1
end

function _M:bash(str) -- luacheck: ignore 212
	local cmd = io.popen(str)
	local result = cmd:read('*all')
	cmd:close()
	return result
end

function _M:telegram_file_link(res) -- luacheck: ignore 212
	--res = table returned by getFile()
	return "https://api.telegram.org/file/bot"..config.telegram.token.."/"..res.filepath
end

function _M:is_silentmode_on(chat_id)
	return p(self).db:get_chat_setting(chat_id, "Silent")
end

function _M:getRules(chat_id)
	local red = p(self).red
	local i18n = p(self).i18n
	local hash = 'chat:'..chat_id..':info'
	local rules = red:hget(hash, 'rules')
	if rules == null then
		return i18n("-*empty*-")
	end
	return rules
end

function _M:getAdminlist(chat)
	local i18n = p(self).i18n
	local db = p(self).db
	local list = db:getChatAdministratorsList(chat)
	if not list then
		return false
	end
	local creator = ""
	local adminlist = ""
	local count = 1
	for _, user_id in pairs(list) do
		local s = " ├ "
		local admin = ChatMember:new({
			chat = chat,
			user = User:new({id=user_id}, p(self)),
		}, p(self))
		if admin.status == "administrator" then
			if count + 1 == #list then
				s = " └ "
			end
			adminlist = adminlist..s..admin.user:getLink().."\n"
			count = count + 1
		end
		if admin.status == "creator" then
			creator = admin.user:getLink()
		end
	end
	if adminlist == "" then
		adminlist = "-"
	end
	if creator == "" then
		creator = "-"
	end
	return i18n("<b>👤 Tạo bởi</b>\n└ %s\n\n<b>👥 Admins</b> (%d)\n%s"):format(creator, #list - 1, adminlist)
end

function _M:getExtraList(chat_id)
	local red = p(self).red
	local i18n = p(self).i18n

	local hash = 'chat:'..chat_id..':extra'
	local commands = red:hkeys(hash)
	if not next(commands) then
		return i18n("Không có lệnh nào được đặt")
	end
	table.sort(commands)
	return i18n("Danh sách các lệnh tùy chỉnh:\n") .. table.concat(commands, '\n')
end

function _M:getSettings(chat_id)
	local red = p(self).red
	local i18n = p(self).i18n

	local hash = 'chat:'..chat_id..':settings'

	local lang = red:get('lang:'..chat_id) -- group language
	if lang == null then lang = config.lang end

	local message = i18n("Cài đặt hiện tại cho *nhóm*:\n\n")
			.. i18n("*Ngôn ngữ*: %s\n"):format(config.available_languages[lang])

	--build the message
	local strings = {
		Welcome = i18n("Tin nhắn chào mừng"),
		Goodbye = i18n("Tin nhắn tạm biệt"),
		Extra = i18n("Thêm"),
		Flood = i18n("Anti-flood"),
		Antibot = i18n("Cấm bots"),
		Silent = i18n("Chế độ im lặng"),
		Rules = i18n("Nội quy"),
		Arab = i18n("Arab"),
		Rtl = i18n("RTL"),
		Reports = i18n("Báo cáo"),
		Weldelchain = i18n("Xóa tin nhắn chào mừng cuối cùng"),
		Welbut = i18n("Nút chào mừng"),
		Clean_service_msg = i18n("Thông báo dịch vụ sạch"),
	} Util.setDefaultTableValue(strings, i18n("Unknown"))
	for key, default in pairs(config.chat_settings['settings']) do

		local off_icon, on_icon = '🚫', '✅'
		if self:is_info_message_key(key) then
			off_icon, on_icon = '👤', '👥'
		end

		local db_val = red:hget(hash, key)
		if db_val == null then db_val = default end

		if db_val == 'off' then
			message = message .. string.format('%s: %s\n', strings[key], off_icon)
		else
			message = message .. string.format('%s: %s\n', strings[key], on_icon)
		end
	end

	--build the char settings lines
	hash = 'chat:'..chat_id..':char'
	local off_icon, on_icon = '🚫', '✅'
	for key, default in pairs(config.chat_settings['char']) do
		local db_val = red:hget(hash, key)
		if db_val == null then db_val = default end
		if db_val == 'off' then
			message = message .. string.format('%s: %s\n', strings[key], off_icon)
		else
			message = message .. string.format('%s: %s\n', strings[key], on_icon)
		end
	end

	--build the "welcome" line
	hash = 'chat:'..chat_id..':welcome'
	local type = red:hget(hash, 'type')
	if type == 'media' then
		message = message .. i18n("*Kiểu chào mừng*: `GIF / sticker`\n")
	elseif type == 'custom' then
		message = message .. i18n("*Kiểu chào mừng*: `custom message`\n")
	elseif type == 'no' then
		message = message .. i18n("*Kiểu chào mừng*: `default message`\n")
	end

	local warnmax_std = red:hget('chat:'..chat_id..':warnsettings', 'max')
	if warnmax_std == null then warnmax_std = config.chat_settings['warnsettings']['max'] end

	local warnmax_media = red:hget('chat:'..chat_id..':warnsettings', 'mediamax')
	if warnmax_media == null then warnmax_media = config.chat_settings['warnsettings']['mediamax'] end

	return message .. i18n("Cảnh cáo (`standard`): *%s*\n"):format(warnmax_std)
		.. i18n("Cảnh cáo (`media`): *%s*\n\n"):format(warnmax_media)
		.. i18n("✅ = _enabled / allowed_\n")
		.. i18n("🚫 = _disabled / not allowed_\n")
		.. i18n("👥 = _sent in group (always for admins)_\n")
		.. i18n("👤 = _sent in private_")

end

function _M:changeSettingStatus(chat_id, field)
	local api = p(self).api
	local red = p(self).red
	local i18n = p(self).i18n

	local turned_off = {
		reports = i18n("@admin command disabled"),
		welcome = i18n("Welcome message won't be displayed from now"),
		goodbye = i18n("Goodbye message won't be displayed from now"),
		extra = i18n("#extra commands are now available only for administrators"),
		flood = i18n("Anti-flood is now off"),
		rules = i18n("/rules will reply in private (for users)"),
		silent = i18n("Silent mode is now off"),
		preview = i18n("Links preview disabled"),
		welbut = i18n("Welcome message without a button for the rules")
	}
	local turned_on = {
		reports = i18n("@admin command enabled"),
		welcome = i18n("Welcome message will be displayed"),
		goodbye = i18n("Goodbye message will be displayed"),
		extra = i18n("#extra commands are now available for all"),
		flood = i18n("Anti-flood is now on"),
		rules = i18n("/rules will reply in the group (with everyone)"),
		silent = i18n("Silent mode is now on"),
		preview = i18n("Links preview enabled"),
		welbut = i18n("The welcome message will have a button for the rules")
	}

	local hash = 'chat:'..chat_id..':settings'
	local now = red:hget(hash, field)
	if now == 'on' then
		red:hset(hash, field, 'off')
		return turned_off[field:lower()]
	else
		red:hset(hash, field, 'on')
		if field:lower() == 'goodbye' then
			local r = api:getChatMembersCount(chat_id)
			if r and r > 50 then
				return i18n("This setting is enabled, but the goodbye message won't be displayed in large groups, "
					.. "because I can't see service messages about left members"), true
			end
		end
		return turned_on[field:lower()]
	end
end

function _M:sendStartMe(msg)
	local api = p(self).api
	local i18n = p(self).i18n
	local bot = p(self).bot
	local reply_markup = ApiUtil.InlineKeyboardMarkup:new():row(
		{text = i18n("Start me"), url = 'https://telegram.me/'..bot.username}
	)
	api:sendMessage(msg.from.chat.id, i18n("_Please message me first so I can message you_"), "Markdown", nil, nil, nil,
		reply_markup)
end

function _M:initGroup(chat)
	local red = p(self).red
	for set, setting in pairs(config.chat_settings) do
		local hash = 'chat:'..chat.id..':'..set
		for field, value in pairs(setting) do
			red:hset(hash, field, value)
		end
	end

	self:cache_adminlist(chat) --init admin cache

	--save group id
	red:sadd('bot:groupsid', chat.id)
	--remove the group id from the list of dead groups
	red:srem('bot:groupsid:removed', chat.id)
	chat:cache()
end

local function empty_modlist(self, chat_id)
	local red = p(self).red
	local set = 'chat:'..chat_id..':mods'
	local mods = red:smembers(set)
	if next(mods) then
		for i=1, #mods do
			red:del(('chat:%d:mod:%d'):format(tonumber(chat_id), tonumber(mods[i])))
		end
	end

	red:del(set)
end

function _M:remGroup(chat_id)
	local db = p(self).db
	empty_modlist(self, chat_id)
	db:deleteChat({id=chat_id})
end

function _M:logEvent(event, msg, extra)
	local api = p(self).api
	local bot = p(self).bot
	local red = p(self).red
	local i18n = p(self).i18n
	local log_id = red:hget('bot:chatlogs', msg.from.chat.id)
	-- self:dump(extra)

	if not log_id or log_id == null then return end
	local is_loggable = red:hget('chat:'..msg.from.chat.id..':tolog', event)
	if not is_loggable == 'yes' then return end

	local text, reply_markup

	local chat_info = i18n("<b>Chat</b>: %s [#chat%d]"):format(msg.from.chat.title:escape_html(), msg.from.chat.id * -1)
	local member = ("%s [@%s] [#id%d]"):format(msg.from.user.first_name:escape_html(), msg.from.user.username or '-',
		msg.from.user.id)

	local log_event = {
		mediawarn = function()
			--MEDIA WARN
			--warns n°: warns
			--warns max: warnmax
			--media type: media
			text = i18n("#%s (<code>%d/%d</code>), <i>%s</i>\n• %s\n• <b>User</b>: %s"):format(
				event:upper(), extra.warns, extra.warnmax, extra.media, chat_info, member)
		end,
		spamwarn = function()
			--SPAM WARN
			--warns n°: warns
			--warns max: warnmax
			--media type: spam_type
			text = i18n("#%s (<code>%d/%d</code>), <i>%s</i>\n• %s\n• <b>User</b>: %s"):format(
				event:upper(), extra.warns, extra.warnmax, extra.spam_type, chat_info, member)
		end,
		flood = function()
			--FLOOD
			--hammered?: hammered
			text = i18n("#%s\n• %s\n• <b>User</b>: %s"):format(event:upper(), chat_info, member)
		end,
		new_chatphoto = function()
			text = i18n('%s\n• %s\n• <b>By</b>: %s'):format('#NEWPHOTO', chat_info, member)
			reply_markup = {
				inline_keyboard = {{{
					text = i18n("Get the new photo"),
					url = ("telegram.me/%s?start=photo_%s"):format(bot.username,
					msg.new_chatphoto[#msg.new_chatphoto].file_id)
				}}}
			}
		end,
		delete_chatphoto = function()
			text = i18n('%s\n• %s\n• <b>By</b>: %s'):format('#PHOTOREMOVED', chat_info, member)
		end,
		new_chat_title = function()
			text = i18n('%s\n• %s\n• <b>By</b>: %s'):format('#NEWTITLE', chat_info, member)
		end,
		pinned_message = function()
			text = i18n('%s\n• %s\n• <b>By</b>: %s'):format('#PINNEDMSG', chat_info, member)
			msg.message_id = msg.pinned_message.message_id --because of the "go to the message" link. The normal msg.message_id brings to the service message
		end,
		report = function()
			text = i18n('%s\n• %s\n• <b>By</b>: %s\n• <i>Reported to %d admin(s)</i>'):format(
			event:upper(), chat_info, member, extra.n_admins)
		end,
		blockban = function()
			text = i18n('#%s\n• %s\n• <b>User</b>: %s [#id%d]'):format(event:upper(), chat_info, extra.name, extra.id)
		end,
		new_chat_member = function()
			local member2 = ("%s [@%s] [#id%d]"):format(msg.new_chat_member.first_name:escape_html(),
				msg.new_chat_member.username or '-', msg.new_chat_member.id)
			text = i18n('%s\n• %s\n• <b>User</b>: %s'):format('#NEW_MEMBER', chat_info, member2)
			if extra then --extra == msg.from.user
				text = text..i18n("\n• <b>Added by</b>: %s [#id%d]"):format(extra:getLink(), extra.id)
			end
		end,
		-- events that requires user + admin
		warn = function()
			--WARN
			--admin name formatted: admin
			--user name formatted: user
			--user id: user_id
			--warns n°: warns
			--warns max: warnmax
			--motivation: motivation
			text = i18n(
				'#%s\n• <b>Admin</b>: %s [#id%d]\n• %s\n• <b>Người dùng</b>: %s [#id%d]\n• <b>Số lần</b>: <code>%d/%d</code>'
			):format(event:upper(), tostring(extra.admin), msg.from.user.id, chat_info, tostring(extra.user), extra.user_id,
				extra.warns, extra.warnmax
			)
		end,
		nowarn = function()
			--WARNS REMOVED
			--admin name formatted: admin
			--user name formatted: user
			--user id: user_id
			text = i18n("#%s\n• <b>Admin</b>: %s [#id%s]\n• %s\n• <b>Người dùng</b>: %s [#id%s]"):format(
				'WARNS_RESET', extra.admin, msg.from.user.id, chat_info, extra.user, extra.user_id)
		end,
		block = function() -- or unblock
			text = i18n('#%s\n• <b>Admin</b>: %s [#id%s]\n• %s\n'
			):format(event:upper(), msg.from.user, msg.from.user.id, chat_info)
			if extra.n then
				text = text..i18n('• <i>Người dùng liên quan: %d</i>'):format(extra.n)
			elseif extra.user then
				text = text..i18n('• <b>Người dùng</b>: %s [#id%d]'):format(extra.user, msg.reply.forward_from.id)
			end
		end,
		tempban = function()
			--TEMPBAN
			--admin name formatted: admin
			--user name formatted: user
			--user id: user_id
			--days: d
			--hours: h
			--motivation: motivation
			text = i18n(
			'#%s\n• <b>Admin</b>: %s [#id%s]\n• %s\n• <b>Người dùng</b>: %s [#id%s]\n• <b>Thời gian</b>: %d ngày, %d giờ'
			):format(event:upper(), tostring(extra.admin), msg.from.user.id, chat_info, tostring(extra.user),
			extra.user_id, extra.d, extra.h)
		end,
		ban = function() -- or kick or unban
			--BAN OR KICK OR UNBAN
			--admin name formatted: admin
			--user name formatted: user
			--user id: user_id
			--motivation: motivation
			text = i18n('#%s\n• <b>Admin</b>: %s [#id%s]\n• %s\n• <b>Người dùng</b>: %s [#id%s]'):format(
				event:upper(), tostring(extra.admin), msg.from.user.id, chat_info, tostring(extra.user), extra.user_id)
		end,
	} Util.setDefaultTableValue(log_event, function()
			text = i18n('#%s\n• %s\n• <b>Bởi</b>: %s'):format(event:upper(), chat_info, member)
	end)

	log_event.unblock = log_event.block
	log_event.kick    = log_event.ban
	log_event.unban   = log_event.ban

	log_event[event]()

	if event == 'ban' or event == 'tempban' then
		--logcb:unban:user_id:chat_id for ban, logcb:untempban:user_id:chat_id for tempban
		reply_markup = {
			inline_keyboard = {{{
				text = i18n("Unban"),
				callback_data = ("logcb:un%s:%d:%d"):format(event, extra.user_id, msg.from.chat.id)
			}}}
		}
	end

	if extra then
		if rawget(extra, "hammered") then
			text = text..i18n("\n• <b>Tiến hành</b>: #%s"):format(extra.hammered:upper())
		end
		if rawget(extra, "motivation") then
			text = text..i18n('\n• <b>Lý do</b>: <i>%s</i>'):format(extra.motivation:escape_html())
		end
	end

	if msg.from.chat.username then
		text = text..('\n• <a href="telegram.me/%s/%d">%s</a>'):format(
			msg.from.chat.username, msg.message_id, i18n('Đi tới tin nhắn')
		)
	end

	local ok, err = api:send_message{
		chat_id = log_id,
		text = text,
		parse_mode = "html",
		disable_webpagepreview = true,
		reply_markup = reply_markup
	}
	if not ok and err.description:match("trò chuyện không tìm thấy") then
		red:hdel('bot:chatlogs', msg.from.chat.id)
	end
end

function _M:is_info_message_key(key) -- luacheck: ignore 212
	if key == 'Extra' or key == 'Rules' then
		return true
	end
	return false
end

function _M:metric_incr(name)
	local red = p(self).red
	red:incr("bot:metrics:" .. name)
end

function _M:metric_set(name, value)
	local red = p(self).red
	red:set("bot:metrics:" .. name, value)
end

function _M:metric_get(name)
	local red = p(self).red
	return red:get("bot:metrics:" .. name)
end

function _M:time_hires() -- luacheck: ignore 212
	return time_hires()
end
return _M
