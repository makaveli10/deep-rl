-- Patrick Emami

require 'torch'
local HC = require 'HC'
local simulator = torch.class("Simulator")

-- ##########################################################
-- Representation of vehicle state. 

-- torch.Tensor(
--    x1:      x position of front center of the ego vehicle,
-- 	  y1:      y position of front center of the ego vehicle,
-- 	  theta1:  heading of the ego vehicle,
-- 	  v1:      velocity of the ego vehicle,
-- 	  x2:      x position of the front center of obstacle vehicle,
-- 	  y2:      y position of the front center of obstacle vehicle,
-- 	  theta2:  heading of the obstacle vehicle,
-- 	  v2:      velocity of the obstacle vehicle
-- )
-- distance is measured in meters, angles in radians
-- velocity in m/s
--
-- Heading is measured such that pi rads is driving north, pi/2 rads is driving east,
-- 0 rads is driving south, and -pi/2 rads is driving west 
-- ##########################################################

--[[
  Parameters:
    * opt - a table of options
      Where `opt` has the following keys:
        * `trajectoryLength` The number of trajectories to simulate
  	    * `vehicleLength` Length of the vehicle
  	    * `vehicleWidth` Width of the vehicle
  	    * `wheelBase` 
  	* env - the simulation environment
  ]]
function simulator:__init(opt, env)
	assert(env) 
	self.scale = opt.scale
	self.env = env
	self.trajectoryLength = opt.trajectoryLength
	self.vehicleState = self:initScenario(env:getScenario(opt.scenario))
	self.vehicleLength = opt.vehicleLength * opt.scale
	self.vehicleWidth = opt.vehicleWidth * opt.scale
	self.wheelBase = opt.wheelBase * opt.scale
	self.dt = opt.dt
	-- Draw the vehicles in their initial states 

	local corners = self:computeCorners()
	-- Ego Vehicle
	self.egoVehicle = HC.rectangle(corners[1][2][1], corners[1][2][2], self.vehicleWidth, self.vehicleLength)
	self.egoVehicle:rotate(torch.totable(self.vehicleState)[3][1])
	
	-- Obstacle Vehicle
	self.obstacleVehicle = HC.rectangle(corners[2][2][1], corners[2][2][2], self.vehicleWidth, self.vehicleLength)
	self.obstacleVehicle:rotate(torch.totable(self.vehicleState)[7][1])

end

-- Only for Love simulations
function simulator:drawEgoVehicle()
	self.egoVehicle:draw('fill')
end

-- Only for Love simulations
function simulator:drawObstacleVehicle()
	self.obstacleVehicle:draw('fill')
end

--[[
  Parameters:
    * scenario - initial states for each vehicle
  ]]
function simulator:initScenario(scenario)
	local state = torch.Tensor(8,1)
	state[1] = scenario[1][1]  -- x (in meters, not pixels)
	state[2] = scenario[1][2]  -- y
	state[3] = scenario[1][3]  -- theta
	state[4] = scenario[1][4]  -- velocity
	state[5] = scenario[2][1]
	state[6] = scenario[2][2]
	state[7] = scenario[2][3]
	state[8] = scenario[2][4]
	return state
end

--[[
	Step the simulator by applying an acceleration and psi for 
	each vehicle 

	Parameters: 
	 * actions - {acc1, acc2, psi1, psi2}

	Returns:
		* reward - scalar reward observed by taking the action 
				in the current state
]]
function simulator:step(actions)
	-- take action, observe new state 
	local reward, isTerminal = self.env:reward(self.egoVehicle, self.obstacleVehicle, actions)
	if not isTerminal then 
		self:updatePosition(actions)
	end 
	return reward, isTerminal
end 

--[[
  Returns: 
  	* torch.Tensor that contains 4 pixel coordinate points of 
  			a rectangular approx for each vehicle 
  ]]
function simulator:computeCorners()
	local x = nil
	local y = nil
	local theta = nil
    local halfWidth = self.vehicleWidth/2
    -- find how much the vehicle hangs over the axles
    local overhang = (self.vehicleLength - self.wheelBase)/2
    local corners = torch.Tensor(2, 4, 2)

	for i=1, 2 do
    	if i == 1 then 
    		x = self.vehicleState[1] * self.scale
    		y = self.vehicleState[2] * self.scale
    		theta = self.vehicleState[3]
    	else
    		x = self.vehicleState[5] * self.scale
    		y = self.vehicleState[6] * self.scale
    		theta = self.vehicleState[7]
    	end   
    
	    -- box approx to car frame
	    Xtl = x:csub(torch.sin(theta):mul(overhang)):csub(torch.cos(theta):mul(halfWidth))
	    Ytl = y:csub(torch.cos(theta):mul(overhang)):add(torch.sin(theta):mul(halfWidth))
	    Xbl = Xtl:add(torch.cos(theta):mul(self.vehicleWidth))
	    Ybl = Ytl:csub(torch.sin(theta):mul(self.vehicleWidth)) 
	    Xtr = Xtl:add(torch.sin(theta):mul(self.vehicleWidth))
	    Ytr = Ytl:add(torch.cos(theta):mul(self.vehicleWidth))
	    Xbr = Xbl:add(torch.sin(theta):mul(self.vehicleLength))
	    Ybr = Ybl:add(torch.cos(theta):mul(self.vehicleLength))

	    corners[i][1][1] = Xtl
	    corners[i][1][2] = Ytl
	    corners[i][2][1] = Xbl
	    corners[i][2][2] = Ybl
	    corners[i][3][1] = Xtr
	    corners[i][3][2] = Ytr
	    corners[i][4][1] = Xbr
	    corners[i][4][2] = Ybr
   	end

   	return corners
end

--[[
	Parameters: 
		* actions - acc and psi for each vehicle
]]
function simulator:updatePosition(actions)
	 -- have the observation vehicle advance its position based on its policy
	 local a = torch.totable(actions)
	 local egoVehicleAccel = a[1]
	 local egoVehiclePsi = a[2]
	 local obstacleVehicleAccel = a[3]
	 local obstacleVehiclePsi = a[4]
	 local oldState = self.vehicleState:clone()
	 local oldEgoVehicleVelocity = torch.mul(oldState[4], self.dt)
	 local oldObstacleVehicleVelocity = torch.mul(oldState[8], self.dt)
	 local z = torch.Tensor(4, 1)
	 local l = self.wheelBase / self.scale
	 local s = 4

	 -- Ego Vehicle state update 
	 -- Check if the vehicle is still in the environment
	 if self.env:isValid(self.vehicleState[{{1, 2}}], self.egoVehicle) then

		 z[1] = oldEgoVehicleVelocity * torch.sin(oldState[3])
		 z[2] = oldEgoVehicleVelocity * torch.cos(oldState[3])
		 z[3] = oldEgoVehicleVelocity / l * torch.tan(egoVehiclePsi)
		 z[4] = egoVehicleAccel * self.dt

		 self.vehicleState[{{1, 4}}] = oldState[{{1, 4}}] + z
		 
		 local dx = self.vehicleState[1] - oldState[1]
		 local dy = self.vehicleState[2] - oldState[2]
		 local dtheta = self.vehicleState[3] - oldState[3]

		 -- Update the HC rectangle
		 self.egoVehicle:moveTo(torch.totable(torch.mul(self.vehicleState[1], self.scale))[1],
		 	torch.totable(torch.mul(self.vehicleState[2], self.scale))[1])

		 self.egoVehicle:rotate(-torch.totable(dtheta)[1])
	 end

	 if self.env:isValid(self.vehicleState[{{5, 6}}], self.obstacleVehicle) then 
		 -- Obstacle Vehicle state update
		 z[1] = oldObstacleVehicleVelocity * torch.sin(oldState[7])
		 z[2] = oldObstacleVehicleVelocity * torch.cos(oldState[7])
		 z[3] = oldObstacleVehicleVelocity / l * torch.tan(obstacleVehiclePsi)
		 z[4] = obstacleVehicleAccel * self.dt

		 self.vehicleState[{{5, 8}}] = oldState[{{5, 8}}] + z
		  
		 local dx = self.vehicleState[5] - oldState[5]
		 local dy = self.vehicleState[6] - oldState[6]
		 local dtheta = self.vehicleState[7] - oldState[7]

		 -- Update the HC rectangle
		 self.obstacleVehicle:moveTo(torch.totable(torch.mul(self.vehicleState[5], self.scale))[1],
		 	torch.totable(torch.mul(self.vehicleState[6], self.scale))[1])

		 self.obstacleVehicle:rotate(-torch.totable(dtheta)[1])
	 end
end

function simulator:state()
	return torch.totable(self.vehicleState)
end
