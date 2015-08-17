local _M = {}

local cjson = require "cjson"
local http = require "resty.http"
local lock = require "resty.lock"
local types = require "pl.types"
local utils = require "api-umbrella.proxy.utils"

local get_packed = utils.get_packed
local is_empty = types.is_empty
local set_packed = utils.set_packed

local check_lock = lock:new("my_locks", {
  ["timeout"] = 0,
})

local api_users = ngx.shared.api_users

local delay = 1 -- in seconds
local new_timer = ngx.timer.at
local log = ngx.log
local ERR = ngx.ERR

local function do_check()
  local _, lock_err = check_lock:lock("load_api_users")
  if lock_err then
    return
  end

  local current_fetch_time = ngx.now() * 1000
  local last_fetched_timestamp = get_packed(api_users, "distributed_last_fetched_timestamp") or { t = math.floor((current_fetch_time - 60 * 1000) / 1000), i = 0 }

  local skip = 0
  local page_size = 250
  local success = true
  repeat
    local httpc = http.new()
    local res, req_err = httpc:request_uri("http://127.0.0.1:8181/docs/api_umbrella/" .. config["mongodb"]["_database"] .. "/api_users", {
      query = {
        extended_json = "true",
        limit = page_size,
        skip = skip,
        sort = "updated_at",
        query = cjson.encode({
          ts = {
            ["$gt"] = {
              ["$timestamp"] = last_fetched_timestamp,
            },
          },
        }),
      },
    })

    local results = nil
    if req_err then
      ngx.log(ngx.ERR, "failed to fetch users from mongodb: ", req_err)
      success = false
    elseif res.body then
      local response = cjson.decode(res.body)
      if response and response["data"] then
        results = response["data"]
        for index, result in ipairs(results) do
          if skip == 0 and index == 1 then
            if result["ts"] and result["ts"]["$timestamp"] then
              set_packed(api_users, "distributed_last_fetched_timestamp", result["ts"]["$timestamp"])
            end
          end

          if result["api_key"] then
            ngx.shared.api_users:delete(result["api_key"])
          end
        end
      end
    end

    skip = skip + page_size
  until is_empty(results)

  if success then
    api_users:set("last_fetched_at", current_fetch_time)
  end

  local ok, unlock_err = check_lock:unlock()
  if not ok then
    ngx.log(ngx.ERR, "failed to unlock: ", unlock_err)
  end
end

local function check(premature)
  if premature then
    return
  end

  local ok, err = pcall(do_check)
  if not ok then
    ngx.log(ngx.ERR, "failed to run api fetch cycle: ", err)
  end

  ok, err = new_timer(delay, check)
  if not ok then
    if err ~= "process exiting" then
      ngx.log(ngx.ERR, "failed to create timer: ", err)
    end

    return
  end
end

function _M.spawn()
  local ok, err = new_timer(0, check)
  if not ok then
    log(ERR, "failed to create timer: ", err)
    return
  end
end

return _M