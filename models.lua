--TODO: make type parser system
--TODO: make sqlite interface thing
function animal()
	local animal = rover.model.new()
	animal:string("type") --nullable should be an option
	animal:number("amount")
	animal:bool("is_alive")
	animal:relation("parent")
	return animal
end
