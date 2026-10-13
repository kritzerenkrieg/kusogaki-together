-- Fixed-timestep clock: the simulation always advances in whole `step` ticks,
-- whatever the frame time, so every machine runs the same steps for the same
-- inputs. See NETWORKING.md (Fixed timestep).
local fixedstep = {}
fixedstep.__index = fixedstep

-- step: tick length in seconds; maxSteps: most ticks run in one frame.
function fixedstep.new(step, maxSteps)
    return setmetatable({
        step = step or 1 / 60,
        maxSteps = maxSteps or 5,
        accumulator = 0,
        tick = 0, -- ticks run since the last reset
    }, fixedstep)
end

-- Run tickFn(step) once per whole step owed. Returns alpha in [0, 1): how far
-- the frame sits between the last tick and the next, for drawing.
-- After a long hitch the backlog beyond maxSteps is dropped (the game slows
-- down for that frame) instead of piling up more work every frame.
function fixedstep:advance(delta, tickFn)
    self.accumulator = self.accumulator + math.max(0, delta)
    local steps = 0
    while self.accumulator >= self.step and steps < self.maxSteps do
        self.tick = self.tick + 1
        tickFn(self.step, self.tick)
        self.accumulator = self.accumulator - self.step
        steps = steps + 1
    end
    if self.accumulator >= self.step then
        self.accumulator = 0
    end
    return self.accumulator / self.step
end

function fixedstep:reset()
    self.accumulator = 0
    self.tick = 0
end

return fixedstep
