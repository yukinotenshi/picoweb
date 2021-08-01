pico-8 cartridge // http://www.pico-8.com
version 32
__lua__
ipc = {
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
    __buffer = {},
    __state = 0,
    -- 1 dimensional map[packet_type]
    __callback = {},
    __last_payload = {},
    -- for sending message
    __message_queue = {},
    __message_type = {},
    __message_context = {},
    __message_seq_num = {}
}

-- if pico8 as sender, packet_type % 2 == 0
-- if external as sender, packet_type % 2 == 1
packet_types = {
    pico_noop = 0,
    ext_noop = 1,
    pico_ping = 2,
    ext_ping = 3,
    pico_pong = 4,
    ext_pong = 5,
    pico_ack = 6,
    ext_ack = 7,
    pico_reject = 8,
    ext_reject = 9,
    pico_start_msg = 10,
    ext_start_msg = 11,
    pico_end_msg = 12,
    ext_end_msg = 13,
    -- the rest should be used for the type of the message itself
}

states = {
    noop = 0,
    wait_msg_start_ack = 1,
    send_msg_in_progress = 2,
    receive_msg_in_progress = 3,
}

function ipc:new (o, gpio_addr, packet_length)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    self.__start_addr = gpio_addr
    self.__type_addr = self.__start_addr
    self.__seq_num_addr = self.__start_addr + 1
    self.__context_addr = self.__start_addr + 2
    self.__pckt_len_addr = self.__start_addr + 3
    self.__pckt_crc_addr = self.__start_addr + 4
    self.__pckt_body_addr = self.__start_addr + 8
    self.__pckt_len = packet_length
    self.__use_file_io = stat(6) == "picoweb"
    self.__state = states.noop
    self:register_callback(3, function () self:__pong() end)
    return o
end

function ipc:__from_serial()
    if not self.__use_file_io then
        return
    end
    serial(0x806, self.__start_addr, self.__pckt_len)
end

function ipc:__to_serial()
    if not self.__use_file_io then
        return
    end
    serial(0x807, self.__start_addr, self.__pckt_len)
end

function ipc:__reset_gpio()
    memset(self.__start_addr, 0, self.__pckt_len)
end

function ipc:__calc_crc(packet_type)
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

function ipc:__send_payload(payload_arr)
    if #payload_arr < 8 then
        return
    end

    for i=1,(self.__pckt_len-#payload_arr) do
        add(payload_arr, 0)
    end

    for i=2,#payload_arr do
        poke(self.__start_addr+i-1, payload_arr[i])
    end

    local crc = self:__calc_crc(payload_arr[1])
    poke(self.__pckt_crc_addr, crc)
    poke(self.__type_addr, payload_arr[1])
    self.__last_payload = payload_arr
end

function ipc:__ping()
    self:__send_payload({
        packet_types.pico_ping, 0, 0, 8, 0, 0, 0, 0
    })
end

function ipc:__pong()
    self:__send_payload({
        packet_types.pico_pong, 0, 0, 8, 0, 0, 0, 0
    })
end

function ipc:__start_msg(context_id, packet_type, message_length)
    self:__send_payload({
        packet_types.pico_start_msg, 0, context_id, 13, 0, 0, 0, 0,
        packet_type,
        message_length & 0b11111111,
        message_length >> 8 & 0b11111111,
        message_length >> 16 & 0b11111111,
        message_length >> 24 & 0b11111111
    })
end

function ipc:__ack()
    self:__send_payload({
        packet_types.pico_ack,
        @self.__seq_num_addr,
        @self.__context_addr,
        9, 0, 0, 0, 0,
        @self.__type_addr
    })
end

function ipc:__reject()
    self:__send_payload({
        packet_types.pico_reject,
        @self.__seq_num_addr,
        @self.__context_addr,
        9, 0, 0, 0, 0,
        @self.__type_addr
    })
end

function ipc:__noop()
    self:__send_payload({
        packet_types.pico_noop,
        0, 0, 8, 0, 0, 0, 0,
    })
end

function ipc:__end_msg()
    self:__send_payload({
        packet_types.pico_end_msg,
        0,
        self.__message_context[1],
        9, 0, 0, 0, 0,
        self.__message_type[1]
    })
end

function ipc:__resend()
    self:__send_payload(self.__last_payload)
end

function ipc:__send_message_part()
    if #self.__message_queue == 0 then
        return
    end

    local msg_part = {}
    if #self.__message_queue[1] <= (self.__pckt_len - 8) then
        msg_part = self.__message_queue[1]
        self.__message_queue[1] = {}
    else
        for i=1,self.__pckt_len-8 do
            add(msg_part, self.__message_queue[1][i])
        end
        for i=1,self.__pckt_len-8 do
            deli(self.__message_queue[1], 1)
        end
    end

    local payload = {
        self.__message_type[1],
        self.__message_seq_num[1],
        self.__message_context[1],
        #msg_part+8,
        0, 0, 0, 0
    }
    for i=1,#msg_part do
        add(payload, msg_part[i])
    end

    self:__send_payload(payload)
    self.__message_seq_num[1] += 1
end

function ipc:__receive_message()
    local len = @self.__pckt_len_addr
    if len < 9 then
        return
    end

    local packet_type = @self.__type_addr
    local context_type = @self.__context_addr

    if self.__buffer[packet_type] == nil then
        self.__buffer[packet_type] = {}
    end

    if self.__buffer[packet_type][context_type] == nil then
        self.__buffer[packet_type][context_type] = {}
    end

    for i=0,len-9 do
        local addr = self.__pckt_body_addr+i
        add(self.__buffer[packet_type][context_type], @addr)
    end

    self:__ack()
end

function ipc:register_callback(packet_type, callback_function)
    self.__callback[packet_type] = callback_function
end

function ipc:check_message()
    self:__from_serial()
    local packet_type = @self.__type_addr
    -- noop, do nothing
    if packet_type == packet_types.ext_noop then
        if #self.__message_queue > 0 and self.__state == states.noop then
            self:__start_msg(
                self.__message_context[1],
                self.__message_type[1],
                #self.__message_queue[1]
            )
            self.__state = states.wait_msg_start_ack
        else
            self:__noop()
        end
        self:__to_serial()
        return
    end

    -- outgoing packets
    if packet_type % 2 == 0 then
        return
    end

    -- doesn't match crc
    local crc = self:__calc_crc(@self.__type_addr)
    if crc != @self.__pckt_crc_addr then
        self:__reject()
        self:__to_serial()
        return
    end

    if packet_type == packet_types.ext_ping or packet_type == packet_types.ext_pong then
        self.__buffer[packet_type] = {}
        self.__buffer[packet_type][@self.__context_addr] = 1
    elseif packet_type == packet_types.ext_start_msg then
        self.__state = states.receive_msg_in_progress
        self:__ack()
    elseif packet_type == packet_types.ext_end_msg then
        self.__state = states.noop
        self:__ack()
    elseif packet_type == packet_types.ext_reject then
        self:__resend()
    elseif packet_type == packet_types.ext_ack then
        if self.__state == states.noop then
            self:__noop()
        end
        if self.__state == states.wait_msg_start_ack then
            self.__state = states.send_msg_in_progress
        end
        if self.__state == states.send_msg_in_progress then
            if #self.__message_queue > 0 and #self.__message_queue[1] > 0 then
                self:__send_message_part()
            else
                self:__end_msg()
                deli(self.__message_queue, 1)
                deli(self.__message_type, 1)
                deli(self.__message_context, 1)
                self.__state = states.noop
            end
        end
    end

    if self.__state == states.receive_msg_in_progress then
        self:__receive_message()
    end

    if self.__state == states.noop then
        for packet_type, messages in pairs(self.__buffer) do
            for context, message in pairs(messages) do
                if self.__callback[packet_type] != nil then
                    self.__callback[packet_type](
                        message
                    )
                end
            end
        end
        self.__buffer = {}
        self.__buffer[0] = {}
        self.__buffer[0][0] = {}
    end
    self:__to_serial()
end

function ipc:send_message(message_arr, message_type, message_context)
    add(self.__message_queue, message_arr)
    add(self.__message_type, message_type)
    add(self.__message_context, message_context)
    add(self.__message_seq_num, 0)
end

__gfx__
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00700700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00077000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00077000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00700700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
