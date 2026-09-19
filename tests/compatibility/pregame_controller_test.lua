-- Load the production module with a small XAction/host protocol double.
-- This tests action binding/state, not physical console input or generation.
local function fixture(platform)
  local calls={starts=0,vanilla=0,expanded=0,backs=0}
  local globals={Platform={[platform]=true},g_CurrentMapParams={}}
  local action_class={}
  function action_class:SetActionShortcuts(key1,key2,pad)
    self.host.shortcuts[self.ActionGamepad]=nil
    self.ActionShortcut,self.ActionShortcut2,self.ActionGamepad=key1,key2,pad
    self.host.shortcuts[pad]=self
  end
  function action_class:new(props,host)
    local action=setmetatable(props,{__index=self})
    action.host=host
    host.actions[#host.actions+1]=action
    if action.ActionGamepad then host.shortcuts[action.ActionGamepad]=action end
    return action
  end
  globals.XAction=action_class
  globals.PGMissionLandingSpotRemastered={Open=function()end}
  local sbm={State={},Engine={Global=function(name)return globals[name]end,Unpack=table.unpack},
    Lifecycle={
      BeginExpandedSession=function()calls.expanded=calls.expanded+1 end,
      BeginVanillaSession=function()calls.vanilla=calls.vanilla+1 end,
    }}
  local env=setmetatable({SuperBigMap=sbm},{__index=_G});env._G=env
  assert(loadfile('Code/sbm_pregame_toggle.lua','t',env))()
  local host={actions={},shortcuts={},context={}}
  function host:ActionById(id)
    for _,action in ipairs(self.actions)do if action.ActionId==id then return action end end
  end
  function host:RemoveAction(action)
    if action.ActionGamepad then self.shortcuts[action.ActionGamepad]=nil end
    for i=#self.actions,1,-1 do if self.actions[i]==action then table.remove(self.actions,i)end end
  end
  function host:UpdateActionViews() self.refreshes=(self.refreshes or 0)+1 end
  function host:Press(button,repeated)
    if self.modal then return end -- native desktop routes modal input to its own host
    local action=self.shortcuts[button]
    if action and not (repeated and action.IgnoreRepeated) then action:OnAction(self,'gamepad')end
  end
  action_class:new({ActionId='back',ActionSortKey='back-original',ActionGamepad='ButtonB',
    OnAction=function()calls.backs=calls.backs+1 end},host)
  action_class:new({ActionId='start',ActionSortKey='start-original',ActionGamepad='ButtonX',
    OnAction=function()calls.starts=calls.starts+1 end},host)
  return sbm.PregameToggle,host,globals,calls
end

for _,platform in ipairs({'ps5','xbox','xbox_one','xbox_series','pc'})do
  local toggle,host,globals,calls=fixture(platform)
  assert(toggle.InstallLandingDialogAction(host))
  local expand=assert(host:ActionById('super_big_map_expand'))
  assert(expand.ActionGamepad=='ButtonA' and expand.IgnoreRepeated==true)
  assert(host:ActionById('start').ActionGamepad=='ButtonX')
  host:Press('ButtonA')
  assert(toggle.IsSelected() and not toggle.ShouldExpandNewMap())
  assert(calls.starts==0 and calls.expanded==0, 'confirm must not start generation')
  host:Press('ButtonA',true)
  assert(toggle.IsSelected(), 'held-button repeats must not undo the selection')
  host:Press('ButtonA')
  assert(not toggle.IsSelected())
  expand:OnAction(host,'mouse')
  assert(toggle.IsSelected(), 'mouse and controller use the same action callback')
  host.modal=true;host:Press('ButtonA');assert(toggle.IsSelected());host.modal=false
  host:Press('ButtonX')
  assert(toggle.ShouldExpandNewMap() and globals.g_CurrentMapParams.SuperBigMapExpandMap==true)
  assert(calls.starts==1 and calls.expanded==1)
  host:Press('ButtonA')
  assert(not toggle.IsSelected() and not toggle.ShouldExpandNewMap())
  host:Press('ButtonX')
  assert(calls.starts==2 and calls.vanilla==1 and not globals.g_CurrentMapParams.SuperBigMapExpandMap)
  host:Press('ButtonA');host:Press('ButtonB')
  assert(not toggle.IsSelected() and calls.backs==1)
  -- Existing/reused dialog: update through the setter, not just a field write.
  host.shortcuts.ButtonA=nil;expand.ActionGamepad=''
  expand.ActionShortcut='F9';expand.ActionShortcut2='Ctrl-F9'
  assert(not toggle.InstallLandingDialogAction(host) and #host.actions==3)
  assert(host.shortcuts.ButtonA==expand and expand.ActionShortcut=='F9' and expand.ActionShortcut2=='Ctrl-F9')
  host:Press('ButtonA');assert(toggle.IsSelected())
  -- Toolbar rebuilt by the engine or another mod: exactly one replacement.
  host:RemoveAction(expand)
  assert(toggle.InstallLandingDialogAction(host) and #host.actions==3)
  assert(host.shortcuts.ButtonA==host:ActionById('super_big_map_expand'))
  toggle.RestoreVanillaBehavior()
  assert(not host:ActionById('super_big_map_expand') and not host.shortcuts.ButtonA)
  assert(host:ActionById('start').ActionSortKey=='start-original')
  assert(host:ActionById('back').ActionSortKey=='back-original')
  assert(not toggle.IsSelected() and not toggle.ShouldExpandNewMap())
end
print('PASS: native confirm binding across platform flags, mouse parity, repeat filtering, separate START, OFF/back, reused/rebuilt dialogs and clean removal')
