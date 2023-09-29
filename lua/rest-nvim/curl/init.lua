local utils = require("rest-nvim.utils")
local curl = require("plenary.curl")
local log = require("plenary.log").new({ plugin = "rest.nvim", level = "debug" })
local config = require("rest-nvim.config")

local M = {}

-- get_or_create_buf checks if there is already a buffer with the rest run results
-- and if the buffer does not exists, then create a new one
M.get_or_create_buf = function()
  local tmp_name = "rest_nvim_results"

  -- Check if the file is already loaded in the buffer
  local existing_bufnr = vim.fn.bufnr(tmp_name)
  if existing_bufnr ~= -1 then
    -- Set modifiable
    vim.api.nvim_buf_set_option(existing_bufnr, "modifiable", true)
    -- Prevent modified flag
    vim.api.nvim_buf_set_option(existing_bufnr, "buftype", "nofile")
    -- Delete buffer content
    vim.api.nvim_buf_set_lines(
      existing_bufnr,
      0,
      vim.api.nvim_buf_line_count(existing_bufnr) - 1,
      false,
      {}
    )

    -- Make sure the filetype of the buffer is httpResult so it will be highlighted
    vim.api.nvim_buf_set_option(existing_bufnr, "ft", "httpResult")

    return existing_bufnr
  end

  -- Create new buffer
  local new_bufnr = vim.api.nvim_create_buf(false, "nomodeline")
  vim.api.nvim_buf_set_name(new_bufnr, tmp_name)
  vim.api.nvim_buf_set_option(new_bufnr, "ft", "httpResult")
  vim.api.nvim_buf_set_option(new_bufnr, "buftype", "nofile")

  return new_bufnr
end

local function create_callback(method, url)
  return function(res)
    if res.exit ~= 0 then
      log.error("[rest.nvim] " .. utils.curl_error(res.exit))
      return
    end
    local res_bufnr = M.get_or_create_buf()
    local content_type = nil

    -- get content type
    for _, header in ipairs(res.headers) do
      if string.lower(header):find("^content%-type") then
        content_type = header:match("application/(%l+)") or header:match("text/(%l+)")
        break
      end
    end

    if config.get("result").show_url then
      --- Add metadata into the created buffer (status code, date, etc)
      -- Request statement (METHOD URL)
      vim.api.nvim_buf_set_lines(res_bufnr, 0, 0, false, { method:upper() .. " " .. url })
    end

    if config.get("result").show_http_info then
      local line_count = vim.api.nvim_buf_line_count(res_bufnr)
      local separator = config.get("result").show_url and 0 or 1
      -- HTTP version, status code and its meaning, e.g. HTTP/1.1 200 OK
      vim.api.nvim_buf_set_lines(
        res_bufnr,
        line_count - separator,
        line_count - separator,
        false,
        { "HTTP/1.1 " .. utils.http_status(res.status) }
      )
    end

    if config.get("result").show_headers then
      local line_count = vim.api.nvim_buf_line_count(res_bufnr)
      -- Headers, e.g. Content-Type: application/json
      vim.api.nvim_buf_set_lines(
        res_bufnr,
        line_count + 1,
        line_count + 1 + #res.headers,
        false,
        res.headers
      )
    end

    --- Add the curl command results into the created buffer
    res.body = utils.format_body(res.body, config.get("result").formatters[content_type])

    -- append response container
    res.body = "#+RESPONSE\n" .. res.body .. "\n#+END"

    local lines = utils.split(res.body, "\n")
    local line_count = vim.api.nvim_buf_line_count(res_bufnr) - 1
    vim.api.nvim_buf_set_lines(res_bufnr, line_count, line_count + #lines, false, lines)

    -- Only open a new split if the buffer is not loaded into the current window
    if vim.fn.bufwinnr(res_bufnr) == -1 then
      local cmd_split = [[vert sb]]
      if config.get("result_split_horizontal") then
        cmd_split = [[sb]]
      end
      if config.get("result_split_in_place") then
        cmd_split = [[bel ]] .. cmd_split
      end
      vim.cmd(cmd_split .. res_bufnr)
      -- Set unmodifiable state
      vim.api.nvim_buf_set_option(res_bufnr, "modifiable", false)
    end

    -- Send cursor in response buffer to start
    utils.move_cursor(res_bufnr, 1)

    -- add syntax highlights for response
    local syntax_file = vim.fn.expand(string.format("$VIMRUNTIME/syntax/%s.vim", content_type))

    if vim.fn.filereadable(syntax_file) == 1 then
      vim.cmd(string.gsub(
        [[
        if exists("b:current_syntax")
          unlet b:current_syntax
        endif
        syn include @%s syntax/%s.vim
        syn region %sBody matchgroup=Comment start=+\v^#\+RESPONSE$+ end=+\v^#\+END$+ contains=@%s

        let b:current_syntax = "httpResult"
      ]],
        "%%s",
        content_type
      ))
    end
  end
end

local function format_curl_cmd(res)
  local cmd = "curl"

  for _, value in pairs(res) do
    if string.sub(value, 1, 1) == "-" then
      cmd = cmd .. " " .. value
    else
      cmd = cmd .. " '" .. value .. "'"
    end
  end

  -- remote -D option
  cmd = string.gsub(cmd, "-D '%S+' ", "")
  return cmd
end

-- curl_cmd runs curl with the passed options, gets or creates a new buffer
-- and then the results are printed to the recently obtained/created buffer
-- @param opts curl arguments
M.curl_cmd = function(opts)
  if opts.dry_run then
    local res = curl[opts.method](opts)
    local curl_cmd = format_curl_cmd(res)

    if config.get("yank_dry_run") then
      vim.cmd("let @+=" .. string.format("%q", curl_cmd))
    end

    vim.api.nvim_echo({ { "[rest.nvim] Request preview:\n", "Comment" }, { curl_cmd } }, false, {})
    return
  else
    opts.callback = vim.schedule_wrap(create_callback(opts.method, opts.url))
    curl[opts.method](opts)
  end
end

return M
