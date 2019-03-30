local data =
{
  machines = {},
  spawner_tick_check = {},
  ghost_tick_check = {},
  not_idle_units = {}
}

local names = names.deployers
local units = names.units
--todo allow other mods to add deployers
local spawner_map = {}
for k, deployer in pairs (names) do
  spawner_map[deployer] = true
end

local direction_enum = {
  [defines.direction.north] = {0, -1},
  [defines.direction.south] = {0, 1},
  [defines.direction.east] = {1, 0},
  [defines.direction.west] = {-1, 0}
}

local deploy_unit = function(source, prototype, count)
  if not (source and source.valid) then return end
  local direction = source.direction
  local offset = direction_enum[direction]
  local name = prototype.name
  local deploy_bounding_box = prototype.collision_box
  local bounding_box = source.bounding_box
  local offset_x = offset[1] * ((bounding_box.right_bottom.x - bounding_box.left_top.x) / 2) + ((deploy_bounding_box.right_bottom.x - deploy_bounding_box.left_top.x) / 2)
  local offset_y = offset[2] * ((bounding_box.right_bottom.y - bounding_box.left_top.y) / 2) + ((deploy_bounding_box.right_bottom.y - deploy_bounding_box.left_top.y) / 2)
  local position = {source.position.x + offset_x, source.position.y + offset_y}
  local surface = source.surface
  local force = source.force
  local deployed = 0
  local can_place_entity = surface.can_place_entity
  local find_non_colliding_position = surface.find_non_colliding_position
  local create_entity = surface.create_entity
  for k = 1, count do
    if not surface.valid then break end
    local deploy_position = can_place_entity{name = name, position = position, direction = direction, force = force, build_check_type = defines.build_check_type.manual} and position or find_non_colliding_position(name, position, 0, 1)
    local unit = create_entity{name = name, position = deploy_position, force = force, direction = direction}
    script.raise_event(defines.events.on_entity_spawned, {entity = unit, spawner = source})
    deployed = deployed + 1
  end
  return deployed
end


-- so if it takes 2 pollution to send a unit, the energy required is 20
local pollution_scale = 10

--Max pollution each spawner can absorb is 10% of whatever the chunk has.
local pollution_max_percent = 0.1
local min_to_take = 1

local prototype_cache = {}

local get_prototype = function(name)
  local prototype = prototype_cache[name]
  if prototype then return prototype end
  prototype = game.entity_prototypes[name]
  prototype_cache[name] = prototype
  return prototype
end

local check_spawner = function(spawner_data)

  local entity = spawner_data.entity
  if not (entity and entity.valid) then return true end

  --entity.surface.create_entity{name = "flying-text", position = entity.position, text = game.tick % 60}

  local recipe = entity.get_recipe()
  if not recipe then
    if spawner_data.background then
      rendering.destroy(spawner_data.background)
      spawner_data.background = nil
    end
    if spawner_data.progress_bar then
      rendering.destroy(spawner_data.progress_bar)
      spawner_data.progress_bar = nil
    end
    return
  end

  local prototype = get_prototype(recipe.name)
  local pollution = entity.surface.get_pollution(entity.position)

  local pollution_to_take = math.max(math.min(pollution, min_to_take), pollution * pollution_max_percent)

  local added_progress = pollution_to_take * pollution_scale
  local max_progress = recipe.energy

  local progress_percent = entity.crafting_progress
  local progress_amount = progress_percent * max_progress
  local new_progress = progress_amount + added_progress
  while new_progress >= max_progress do
    new_progress = new_progress - max_progress
    -- Fragile!
    deploy_unit(entity, prototype, 1)
    entity.force.item_production_statistics.on_flow(recipe.name, 1)
  end

  local item_count = entity.get_item_count(recipe.name)
  if item_count > 0 then
    deploy_unit(entity, prototype, item_count)
    entity.remove_item{name = recipe.name, count = item_count}
  end

  entity.crafting_progress = new_progress / max_progress
  entity.surface.pollute(entity.position, -pollution_to_take)

  local background = spawner_data.background
  if not background then
    background = rendering.draw_line
    {
      color = {r = 0, b = 0, g = 0},
      width = 10,
      from = entity,
      from_offset = {-33/32, 1},
      to = entity,
      to_offset = {33/32, 1},
      surface = entity.surface,
      forces = {entity.force}
    }
    spawner_data.background = background
  end

  local progress_bar = spawner_data.progress_bar
  if not progress_bar then
    progress_bar = rendering.draw_line
    {
      color = {r = 1, g = 0.5},
      width = 8,
      from = entity,
      from_offset = {-1, 1},
      to = entity,
      to_offset = {1, 1},
      surface = entity.surface,
      forces = {entity.force}
    }
    spawner_data.progress_bar = progress_bar
  end
  rendering.set_to(spawner_data.progress_bar, entity, {(2 * (new_progress / max_progress)) - 1, 1})

end

local try_to_revive_spawner = function(entity)
  local revived = entity.revive({raise_revive = true})
  if revived then return true end
  local units = {}
  for k, unit in pairs (entity.surface.find_entities_filtered{area = entity.bounding_box, force = entity.force, type = "unit"}) do
    units[unit.name] = (units[unit.name] or 0) + 1
    unit.destroy()
  end
  local revived = entity.revive({raise_revive = true})
  if revived then
    for name, count in pairs (units) do
      deploy_unit(entity, get_prototype(name), count)
    end
    return true
  end
  for name, count in pairs (units) do
    for k = 1, count do
      surface.create_entity
      {
        name = name,
        position = surface.find_non_colliding_position(name, entity.position, 0, 1),
        force = entity.force
      }
    end
  end
end

local is_idle = function(unit_number)
  return not (data.not_idle_units[unit_number]) --and remote.call("unit_control", "is_unit_idle", unit.unit_number)
end

local required_pollution =
{
  [names.biter_deployer] = 100,
  [names.spitter_deployer] = 200
}

local check_ghost = function(ghost_data)
  local entity = ghost_data.entity
  if not (entity and entity.valid) then return true end
  local surface = entity.surface
  --entity.surface.create_entity{name = "flying-text", position = entity.position, text = ghost_data.required_pollution}

  for k, unit in pairs (surface.find_entities_filtered{area = entity.bounding_box, force = entity.force, type = "unit"}) do
    local prototype = get_prototype(unit.name)
    local pollution = prototype.pollution_to_join_attack
    if unit.destroy({raise_destroy = true}) then
      ghost_data.required_pollution = ghost_data.required_pollution - pollution
    end
    if ghost_data.required_pollution <= 0 then
      return try_to_revive_spawner(entity)
    end
  end

  local origin = entity.position
  local r = get_prototype(entity.ghost_name).radius * 4
  local area = {{x = origin.x - r, y = origin.y - r}, {x = origin.x + r, y = origin.y + r}}
  local command =
  {
    type = defines.command.go_to_location,
    destination_entity = entity,
    radius = 1
  }
  local needed_pollution = ghost_data.required_pollution
  local check_control = false --  remote.interfaces["unit_control"]
  for k, unit in pairs (surface.find_entities_filtered{area = area, force = entity.force, type = "unit"}) do
    local unit_number = unit.unit_number
    if is_idle(unit_number) then
      --entity.surface.create_entity{name = "flying-text", position = unit.position, text = "IDLE"}
      unit.set_command(command)
      needed_pollution = needed_pollution - unit.prototype.pollution_to_join_attack
      data.not_idle_units[unit_number] = game.tick
    else
      --entity.surface.create_entity{name = "flying-text", position = unit.position, text = "NOT IDLE"}
    end
    --if needed_pollution <= 0 then break end
  end

  local background = ghost_data.background
  if not background then
    background = rendering.draw_line
    {
      color = {r = 0, b = 0, g = 0},
      width = 10,
      from = entity,
      from_offset = {-33/32, 1},
      to = entity,
      to_offset = {33/32, 1},
      surface = entity.surface,
      forces = {entity.force}
    }
    ghost_data.background = background
  end

  local progress_bar = ghost_data.progress_bar
  if not progress_bar then
    progress_bar = rendering.draw_line
    {
      color = {r = 1, g = 0},
      width = 8,
      from = entity,
      from_offset = {-1, 1},
      to = entity,
      to_offset = {1, 1},
      surface = entity.surface,
      forces = {entity.force}
    }
    ghost_data.progress_bar = progress_bar
  end
  rendering.set_to(ghost_data.progress_bar, entity, {(2 * (1 - (ghost_data.required_pollution / required_pollution[entity.ghost_name]))) - 1, 1})

end

-- So, 59, so that its not exactly 60. Which means over a minute or so, each spawner will 'go first' at the pollution.
local spawners_update_interval = 59

local spawner_built = function(entity, tick)
  local spawner_data = {entity = entity}
  local update_tick = 1 + tick + (entity.unit_number % spawners_update_interval)
  data.spawner_tick_check[update_tick] = data.spawner_tick_check[update_tick] or {}
  data.spawner_tick_check[update_tick][entity.unit_number] = spawner_data
end

local ghost_update_interval = 60

local spawner_ghost_built = function(entity, tick)
  local pollution = required_pollution[entity.ghost_name]
  local ghost_data = {entity = entity, required_pollution = pollution}
  local update_tick = 1 + tick + (entity.unit_number % ghost_update_interval)
  data.ghost_tick_check[update_tick] = data.ghost_tick_check[update_tick] or {}
  data.ghost_tick_check[update_tick][entity.unit_number] = ghost_data
  check_ghost(ghost_data)
end

local on_built_entity = function(event)
  local entity = event.created_entity or event.entity
  if not (entity and entity.valid) then return end

  if (spawner_map[entity.name]) then
    return spawner_built(entity, event.tick)
  end

  if entity.type == "entity-ghost" then
    local ghost_name = entity.ghost_name
    if spawner_map[ghost_name] then
      return spawner_ghost_built(entity, event.tick)
    end
  end

end

local check_spawners_on_tick = function(tick)
  local entities = data.spawner_tick_check[tick]
  if not entities then return end
  --local profiler = game.create_profiler()
  data.spawner_tick_check[tick + spawners_update_interval] = entities
  for unit_number, spawner_data in pairs (entities) do
    if check_spawner(spawner_data) then
      entities[unit_number] = nil
    end
  end
  data.spawner_tick_check[tick] = nil
  --game.print({"", profiler, "    "..game.tick})
end

local check_ghosts_on_tick = function(tick)
  local entities = data.ghost_tick_check[tick]
  if not entities then return end
  data.ghost_tick_check[tick + ghost_update_interval] = entities
  for unit_number, ghost_data in pairs (entities) do
    if check_ghost(ghost_data) then
      entities[unit_number] = nil
    end
  end
  data.spawner_tick_check[tick] = nil
end

local expiry_time = 120
local sanity_max = 100
local check_not_idle_units = function(tick)
  if tick % expiry_time ~= 0 then return end
  local expiry_tick = tick - expiry_time
  local max = sanity_max
  for unit_number, tick in pairs (data.not_idle_units) do
    if tick <= expiry_tick then
      data.not_idle_units[unit_number] = nil
    end
    max = max - 1
    if max <= 0 then
      --game.print("INSANE!!")
      return
    end
  end
end

local on_tick = function(event)
  check_spawners_on_tick(event.tick)
  check_ghosts_on_tick(event.tick)
  check_not_idle_units(event.tick)
end

local events =
{
  [defines.events.on_built_entity] = on_built_entity,
  [defines.events.on_robot_built_entity] = on_built_entity,
  [defines.events.script_raised_revive] = on_built_entity,
  [defines.events.on_tick] = on_tick
}

local unit_deployment = {}

unit_deployment.get_events = function() return events end

unit_deployment.on_init = function()
  global.unit_deployment = global.unit_deployment or data
  unit_deployment.on_event = handler(events)
end

unit_deployment.on_load = function()
  data = global.unit_deployment
  unit_deployment.on_event = handler(events)
end

return unit_deployment