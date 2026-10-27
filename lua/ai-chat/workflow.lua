local M = {}

local RESERVED = { COMPLETE = true, ABORT = true }

M.NOTICE = table.concat({
  "この workflow 中はコマンドを実行できません。",
  "コマンドの実行をユーザーに依頼しないでください（`@cmd:` の依頼も不要です）。",
  "与えられた情報だけで判断し、足りない情報があれば出力にその旨を明記してください。",
}, "\n")

M.default = {
  max_steps = 10,
  steps = {
    {
      name = "plan",
      persona = "あなたは設計担当です。コードの変更方針を立てますが、実装コードは書きません。",
      instruction = "次のタスクについて、変更方針と対象ファイルを箇条書きで整理してください。コードは書かないでください。\n\n## タスク\n{task}",
    },
    {
      name = "implement",
      persona = "あなたは実装担当です。計画に従って、最小限の変更を実装します。",
      instruction = "次のタスクを、計画に従って実装してください。変更は SEARCH/REPLACE 形式で出してください。\n\n## タスク\n{task}\n\n## 計画\n{previous_response}",
      edits = true,
    },
    {
      name = "review",
      persona = "あなたはコードレビュー担当です。問題点の指摘のみを行い、コードの書き直しはしません。指摘にコードブロックは使わず、文章で書いてください。",
      instruction = "次のタスクに対する実装をレビューしてください。バグ、仕様の取りこぼし、既存コードとの不整合があれば具体的に指摘してください。コード中の `TODO:` コメントは未決定部分の意図的な印なので指摘しないでください。問題がなければ承認、修正が必要なら指摘を具体的に書いて却下してください。\n\n## 機械検査の結果（フェンス・SEARCH/REPLACE の整合性）\n{edit_check}\n\nここに挙がった問題は必ず指摘して却下してください。\n\n## タスク\n{task}\n\n## 実装\n{last_edit}",
      rules = {
        { marker = "APPROVE", next = "COMPLETE" },
        { marker = "REJECT", next = "fix" },
      },
    },
    {
      name = "fix",
      persona = "あなたは修正担当です。レビューの指摘を反映して実装を直します。",
      instruction = "レビューの指摘を反映して、変更を出し直してください。変更は SEARCH/REPLACE 形式で、元のファイルに対する変更全体を出してください（前回の実装との差分ではありません）。\n\n## タスク\n{task}\n\n## 前回の実装\n{last_edit}\n\n## レビューの指摘\n{previous_response}",
      next = "review",
      edits = true,
    },
  },
}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- {task} などのテンプレート変数を展開する。未知の変数はそのまま残す。
function M.render(template, vars)
  return (template:gsub("{([%w_]+)}", function(key)
    local v = vars[key]
    if v == nil then return nil end
    return tostring(v)
  end))
end

M.EDIT_CHECK_OK = "問題は検出されませんでした。"

-- validate_edit の結果を `{edit_check}` 用の文字列にする
function M.format_edit_check(problems)
  if #problems == 0 then return M.EDIT_CHECK_OK end
  local lines = {}
  for _, p in ipairs(problems) do table.insert(lines, "- " .. p) end
  return table.concat(lines, "\n")
end

-- 最後に現れる単独行のマーカー `[NAME]` を取り出す。
-- 返り値: マーカーを除いた本文, マーカー名（無ければ nil）
function M.parse_marker(text)
  local lines = vim.split(text, "\n", { plain = true })
  for i = #lines, 1, -1 do
    local marker = lines[i]:match("^%[(%u[%u_]*)%]%s*$")
    if marker then
      table.remove(lines, i)
      return (table.concat(lines, "\n"):gsub("%s+$", "")), marker
    end
  end
  return text, nil
end

function M.find_step(def, name)
  for i, step in ipairs(def.steps) do
    if step.name == name then return i, step end
  end
  return nil
end

-- 定義の検証。問題があればメッセージを、無ければ nil を返す。
function M.validate(def)
  if type(def) ~= "table" then return "definition must be a table" end
  if def.max_steps ~= nil and (type(def.max_steps) ~= "number" or def.max_steps < 1) then
    return "max_steps must be a positive number"
  end
  if type(def.steps) ~= "table" or #def.steps == 0 then
    return "steps must be a non-empty list"
  end
  local names = {}
  for i, step in ipairs(def.steps) do
    local where = "steps[" .. i .. "]"
    if type(step) ~= "table" then return where .. " must be a table" end
    if type(step.name) ~= "string" or step.name == "" then return where .. ".name is required" end
    if RESERVED[step.name] then return where .. ".name must not be " .. step.name end
    if names[step.name] then return "duplicate step name: " .. step.name end
    names[step.name] = true
    if type(step.persona) ~= "string" then return where .. ".persona is required" end
    if type(step.instruction) ~= "string" then return where .. ".instruction is required" end
  end
  local function check_target(target, where)
    if type(target) ~= "string" then return where .. " must be a string" end
    if not RESERVED[target] and not names[target] then
      return where .. ": unknown step '" .. target .. "'"
    end
  end
  for _, step in ipairs(def.steps) do
    if step.next ~= nil then
      local err = check_target(step.next, "step '" .. step.name .. "'.next")
      if err then return err end
    end
    if step.rules ~= nil then
      if type(step.rules) ~= "table" or #step.rules == 0 then
        return "step '" .. step.name .. "'.rules must be a non-empty list"
      end
      for j, rule in ipairs(step.rules) do
        local where = "step '" .. step.name .. "'.rules[" .. j .. "]"
        if type(rule) ~= "table" or type(rule.marker) ~= "string" or not rule.marker:match("^%u[%u_]*$") then
          return where .. ".marker must be an upper-case name"
        end
        local err = check_target(rule.next, where .. ".next")
        if err then return err end
      end
    end
  end
  return nil
end

-- step の instruction を展開し、rules があればマーカー出力の指示を末尾に足す。
function M.build_instruction(step, vars)
  local text = M.render(step.instruction, vars)
  if step.rules and #step.rules > 0 then
    local markers, seen = {}, {}
    for _, rule in ipairs(step.rules) do
      if not seen[rule.marker] then
        seen[rule.marker] = true
        table.insert(markers, "[" .. rule.marker .. "]")
      end
    end
    text = text
      .. "\n\n最後の行に、次のいずれか 1 つだけを単独の行として出力してください：\n"
      .. table.concat(markers, " / ")
  end
  return text
end

-- 次の遷移先を決める。返り値: 遷移先（step 名 / "COMPLETE" / "ABORT"）, ABORT の理由
function M.next_step(def, step, marker)
  local target
  if step.rules then
    if not marker then
      return "ABORT", "no marker found in step '" .. step.name .. "'"
    end
    for _, rule in ipairs(step.rules) do
      if rule.marker == marker then
        target = rule.next
        break
      end
    end
    if not target then
      return "ABORT", "unknown marker [" .. marker .. "] in step '" .. step.name .. "'"
    end
  elseif step.next then
    target = step.next
  else
    local idx = M.find_step(def, step.name)
    local following = idx and def.steps[idx + 1]
    target = following and following.name or "COMPLETE"
  end
  if target == "ABORT" then
    return "ABORT", "step '" .. step.name .. "' requested ABORT"
  end
  if target == "COMPLETE" then return "COMPLETE" end
  if not M.find_step(def, target) then
    return "ABORT", "unknown step '" .. target .. "'"
  end
  return target
end

-- ビルトイン < グローバル < ローカル の順にマージする。
-- 返り値: { [name] = { def = ..., source = "builtin"|"global"|"local" } }
function M.merge(global, localdefs)
  local map = {}
  local function add(source, defs)
    for name, def in pairs(defs or {}) do
      map[name] = { def = def, source = source }
    end
  end
  add("builtin", { default = M.default })
  add("global", global)
  add("local", localdefs)
  return map
end

-- <cwd>/.ai-chat/workflows.lua を読む（vim.secure.read で trust 確認を通す）。
-- 返り値: テーブル / nil（無い・拒否）, エラーメッセージ（評価に失敗した場合）
function M.load_local()
  local path = vim.fn.getcwd() .. "/.ai-chat/workflows.lua"
  if vim.fn.filereadable(path) == 0 then return nil end
  local content = vim.secure.read(path)
  if not content then return nil end
  local chunk, err = (loadstring or load)(content, "@" .. path)
  if not chunk then return nil, err end
  local ok, result = pcall(chunk)
  if not ok then return nil, tostring(result) end
  if type(result) ~= "table" then return nil, "must return a table" end
  return result
end

function M.resolve(opts)
  local localdefs, err = M.load_local()
  return M.merge(opts.workflows, localdefs), err
end

function M.list_lines(map)
  local names = vim.tbl_keys(map)
  table.sort(names)
  local lines = { "", "--- workflows ---" }
  for _, name in ipairs(names) do
    table.insert(lines, ("  %s (%s)"):format(name, map[name].source))
  end
  table.insert(lines, "")
  return lines
end

-- `/workflow` の引数を (workflow 名, task) に分ける。引数が空なら nil。
function M.parse_args(full_rest, map)
  local text = trim(full_rest or "")
  if text == "" then return nil end
  local first, rest = text:match("^(%S+)%s*(.*)$")
  if map[first] then return first, trim(rest) end
  return "default", text
end

-- workflow の実行ループ。
-- env:
--   model_for(step)                  step で使うモデル名
--   request(step, user_text, cb)     1 回のリクエスト。cb = { on_complete(text), on_error(msg) }
--   print(lines)                     出力ペインへの追記
--   mark_edit_start()                gA の対象範囲の起点を記録
--   check_edit(text)                 edits step の出力の機械検査。問題の説明のリストを返す（任意）
--   is_cancelled()                   ユーザーが中断したか
--   on_end()                         終了通知（任意）
function M.run(def, name, task, env)
  local max_steps = def.max_steps or 10
  local vars = { task = task, previous_response = "", last_edit = "", edit_check = "", iteration = 0 }
  local count = 0
  local finished = false

  local function finish(result, reason)
    if finished then return end
    finished = true
    local lines = { "", ("--- workflow: %s (%d steps) ---"):format(result, count) }
    if reason then table.insert(lines, reason) end
    table.insert(lines, "")
    env.print(lines)
    if env.on_end then env.on_end() end
  end

  local run_step
  run_step = function(step)
    if count >= max_steps then
      return finish("ABORT", ("max_steps (%d) reached"):format(max_steps))
    end
    count = count + 1
    vars.iteration = count
    env.print({ "", ("### [%d/%d] %s (%s)"):format(count, max_steps, step.name, env.model_for(step)), "" })
    if step.edits then env.mark_edit_start() end

    local handled = false
    env.request(step, M.build_instruction(step, vars), {
      on_complete = function(text)
        if handled then return end
        handled = true
        local body, marker = M.parse_marker(text)
        vars.previous_response = body
        if step.edits then
          vars.last_edit = body
          if env.check_edit then
            vars.edit_check = M.format_edit_check(env.check_edit(body))
            if vars.edit_check ~= M.EDIT_CHECK_OK then
              env.print(vim.split("\n[edit check]\n" .. vars.edit_check .. "\n", "\n", { plain = true }))
            end
          end
        end
        local target, reason = M.next_step(def, step, marker)
        if target == "COMPLETE" then
          finish("COMPLETE")
        elseif target == "ABORT" then
          finish("ABORT", reason)
        else
          local _, next_step = M.find_step(def, target)
          run_step(next_step)
        end
      end,
      on_error = function(msg)
        if handled then return end
        handled = true
        if env.is_cancelled() then
          finish("ABORT", "stopped by user")
        else
          finish("ABORT", "error: " .. msg)
        end
      end,
    })
  end

  env.print({ "", ("--- workflow: %s ---"):format(name) })
  run_step(def.steps[1])
end

return M
