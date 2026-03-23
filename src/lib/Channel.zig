pub fn Channel(Receiver: type, Sender: type) type {
    return struct {
        sender: Sender,
        receiver: Receiver,
        state: enum { waiting, finished },

        pub fn send(Sender) Receiver {}
        pub fn recieve() Receiver {}
    };
}

//How I want channels to work
//Create channel in lua
//Lua is yielded and returns whatever was in the channel(some type of signal to the runtime to do some other task)
//Runtime interprets signal and determines type of channel based on given data
//Data is passed to repsonsible channel
//Ouput retunred to lua
