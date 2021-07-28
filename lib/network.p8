pico-8 cartridge // http://www.pico-8.com
version 32
__lua__
network = {
    __start_addr = 0x5f80,
    __type_addr = 0x5f80,
    __seq_num_addr = 0x5f81,
    __context_addr = 0x5f82,
    __pckt_len_addr = 0x5f83,
    __pckt_crc_addr = 0x5f84,
    __pckt_body_addr = 0x5f88,
    __pckt_len = 96,
    __use_file_io = false,
    -- 2 dimensional map[pckt_type][context_id]
    __buffer = {[1]={[0]=0,},},
    __state = {},
    -- 1 dimensional map[packet_type]
    __callback = {},
}

-- if pico8 as sender, packet_type % 2 == 0
-- if external as sender, packet_type % 2 == 1
packet_types = {
    noop = 0,
    ext_ping = 1,
    pico_ping = 2,
    ext_pong = 3,
    pico_pong = 4,
    ext_ack = 5,
    pico_ack = 6,
    ext_start_msg = 7,
    pico_start_msg = 8,
    ext_end_msg = 9,
    pico_end_msg = 10,
    -- the rest should be used for the type of the message itself
}

function network:new (o, gpio_addr, packet_length)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    self.__start_addr = gpio_addr
    self.__type_addr = self.__start_addr
    self.__seq_num_addr = self.__start_addr + 1
    self.__context_addr = self.__start_addr + 2
    self.__pckt_len_addr = self.__start_addr + 3
    self.__pckt_crc_addr = self.__start_addr + 4
    self.__pckt_body_addr = self.__pckt_body_addr + 8
    self.__pckt_len = packet_length
    self.__use_file_io = stat(6) == "picoweb"
    print(self)
    self:register_callback(1, function () self:__pong() end)
    return o
end

function network:__from_serial()
    if not self.__use_file_io then
        return
    end
    serial(0x806, self.__start_addr, self.__pckt_len)
end

function network:__to_serial()
    if not self.__use_file_io then
        return
    end
    serial(0x807, self.__start_addr, self.__pckt_len)
end

function network:__reset_gpio()
    memset(self.__start_addr, 0, self.__pckt_len)
end

function network:__calc_crc(packet_type)
    local packet_length = @(self.__pckt_len_addr)
    local crc = packet_type
    for i=1,packet_length-1 do
        local addr = self.__start_addr+i
        if addr == self.__pckt_crc_addr then
            goto continue
        end
        crc = bxor(crc, @addr)
        ::continue::
    end
    return crc
end

function network:__send_payload(payload_arr)
    if #payload_arr < 8 then
        return
    end

    for i=2,#payload_arr do
        poke(self.__start_addr+i-1, payload_arr[i])
    end

    local crc = self:__calc_crc(payload_arr[1])
    poke(self.__pckt_crc_addr, crc)
    poke(self.__type_addr, payload_arr[1])
end

function network:__ping()
    self:__send_payload({
        packet_types.pico_ping, 0, 0, 8, 0, 0, 0, 0
    })
end

function network:__pong()
    self:__send_payload({
        packet_types.pico_pong, 0, 0, 8, 0, 0, 0, 0
    })
    print("pong")
end

function network:__start_msg(context_id, packet_type, message_length)
    self:__send_payload({
        packet_types.pico_start_msg, 0, context_id, 13, 0, 0, 0, 0, 
        packet_type,
        message_length & 0b11111111,
        message_length >> 8 & 0b11111111,
        message_length >> 16 & 0b11111111,
        message_length >> 24 & 0b11111111
    })
end

function network:__ack()
    self:__send_payload({
        packet_types.pico_ack,
        @self.__seq_num_addr,
        @self.__context_addr,
        9, 0, 0, 0, 0,
        @self.__type_addr
    })
end

function network:__end_msg(context_id, packet_type)
    self:__send_payload({
        packet_types.pico_end_msg,
        0,
        context_id,
        9, 0, 0, 0, 0,
        packet_type
    })
end

function network:register_callback(packet_type, callback_function)
    self.__callback[packet_type] = callback_function
end

function network:loop()
    self:__from_serial()
    local packet_type = @self.__type_addr
    -- noop, do nothing
    if packet_type == 0 then
        return
    end

    -- outgoing packets
    if packet_type % 2 == 0 then
        return
    end

    -- doesn't match crc
    local crc = self:__calc_crc(@self.__type_addr)
    if crc != @self.__pckt_crc_addr then
        self:__reset_gpio()
        return
    end

    if self.__callback[packet_type] != nil then
        if self.__buffer[packet_type] != nil and self.__buffer[packet_type][@self.__context_addr] != nil then
            self.__callback[packet_type](self.__buffer[packet_type][@self.__context_addr])
        end
    end
    self:__to_serial()
end

net = {}

function _init()
    net = network:new(nil, 0x5f80, 96)
end

function _update()
	net:loop()
end

__gfx__
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00700700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00077000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00077000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00700700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
