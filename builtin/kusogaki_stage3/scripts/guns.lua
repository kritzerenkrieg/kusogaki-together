-- Level script: the dambos' rifles (entities/dambo.lua, entities/bullet.lua).
-- A dambo with a shot due gets its bullet and muzzle flash here, because an
-- entity cannot spawn others itself. Bullets fly straight, and are gone when
-- they hit a wall, block or prop or have flown for their life.
local guns = {}

local function overlaps(bullet, other)
    return math.abs(bullet.x - other.x) < (bullet.w + other.w) / 2
        and math.abs(bullet.y - other.y) < (bullet.h + other.h) / 2
end

-- Anything it stops at: the level's statics (ground, blocks, hazards) and loose
-- props such as boxes. It flies through enemies.
local function hitsSomething(level, bullet)
    for _, solid in ipairs(level.statics) do
        if overlaps(bullet, solid) then
            return true
        end
    end
    for _, prop in ipairs(level.props) do
        if not prop.held and overlaps(bullet, prop) then
            return true
        end
    end
    return false
end

function guns.update(delta, level)
    for _, enemy in ipairs(level.enemies) do
        if enemy.typeName == "dambo" and enemy.fire then
            enemy.fire = false
            if not enemy.killedBy and not enemy.held then
                local x, y = enemy:muzzle()
                level:spawnEntity("bullet", x, y, { dir = enemy.facing })
                enemy:muzzleFlash(x, y, enemy.facing)
            end
        end
    end
    for i = #level.triggers, 1, -1 do
        local bullet = level.triggers[i]
        if bullet.typeName == "bullet" then
            bullet.x = bullet.x + bullet.dir * bullet.speed * delta
            bullet.age = bullet.age + delta
            if hitsSomething(level, bullet) then
                bullet:bulletImpact(bullet.dir)
                level:removeEntity(bullet)
            elseif bullet.age >= bullet.life then
                level:removeEntity(bullet)
            end
        end
    end
end

return guns
