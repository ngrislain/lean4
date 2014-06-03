local f = Const("f")
local x = Var(1)
local y = Var(2)
local t = f(x, y)
check_error(function() t:lower_free_vars(2, 10) end)
check_error(function() t:lower_free_vars(2) end)
check_error(function() t:lower_free_vars(1, 1, 2) end)
assert(t:lower_free_vars(1) == f(Var(0), Var(1)))

