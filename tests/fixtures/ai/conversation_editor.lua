-- Disposable nested editor for the controller-pipe EOF integration check.
local driver = assert(require("ai.conversation_driver").new({
  command = {
    vim.fn.exepath("python3"),
    "-I",
    "-B",
    vim.fs.dirname(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))
      .. "/conversation_controller.py",
    "exit-on-eof",
    arg[1],
  },
}))
local owner = assert(require("ai.conversation").new({
  root = "/tmp/conversation-editor-fixture",
  selection = { "example.txt" },
  model = "fixture/model",
  driver = driver,
}))
owner:subscribe(function(view)
  if view.phase == "generating" then
    vim.schedule(function()
      vim.cmd("qa!")
    end)
  end
end)
assert(
  owner:dispatch({ kind = "submit", text = "wait for editor EOF" }, owner:snapshot().view_revision)
)
assert(
  vim.wait(2000, function()
    return false
  end, 5),
  "Editor never reached the EOF test exit"
)
