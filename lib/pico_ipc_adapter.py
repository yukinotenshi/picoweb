class PacketTypes:
    pico_noop = 0
    ext_noop = 1
    pico_ping = 2
    ext_ping = 3
    pico_pong = 4
    ext_pong = 5
    pico_ack = 6
    ext_ack = 7
    pico_reject = 8
    ext_reject = 9
    pico_start_msg = 10
    ext_start_msg = 11
    pico_end_msg = 12
    ext_end_msg = 13


class PicoIPCStates:
    noop = 0
    wait_msg_start_ack = 1
    send_msg_in_progress = 2
    receive_msg_in_progress = 3


class PicoIPCAdapter:
    def __init__(self, input_file, output_file, packet_length=96):
        self.__start_addr = 0
        self.__type_addr = self.__start_addr
        self.__seq_num_addr = self.__start_addr + 1
        self.__context_addr = self.__start_addr + 2
        self.__pckt_len_addr = self.__start_addr + 3
        self.__pckt_crc_addr = self.__start_addr + 4
        self.__pckt_body_addr = self.__start_addr + 8
        self.__pckt_len = packet_length
        self.__buffer = {}
        self.__state = 0
        self.__callback = {}
        self.__message_queue = []
        self.__message_type = []
        self.__message_context = []
        self.__message_seq_num = []
        self.__last_payload = bytearray([])
        self.__current_packet = bytearray([])
        self.__input_file = input_file
        self.__output_file = output_file
        self.__callback[PacketTypes.pico_ping] = lambda x: self.pong

    def __calc_crc(self, packet_type):
        packet_length = self.__current_packet[self.__pckt_len_addr]
        crc = packet_type
        for i in range(1, packet_length):
            if i == self.__pckt_crc_addr:
                continue
            crc = crc ^ self.__current_packet[i]

        return crc

    def __send_payload(self, payload_bytearray):
        if len(payload_bytearray) < 8:
            return

        self.__current_packet = payload_bytearray
        crc = self.__calc_crc(payload_bytearray[self.__type_addr])
        self.__current_packet[self.__pckt_crc_addr] = crc
        for x in range(self.__pckt_len - len(self.__current_packet)):
            self.__current_packet.append(0)

        with open(self.__input_file, 'ab') as f:
            f.write(self.__current_packet)

        self.__last_payload = bytearray([x for x in self.__current_packet])
        return

    def ping(self):
        self.__send_payload(bytearray([
            PacketTypes.ext_ping, 0, 0, 8, 0, 0, 0, 0
        ]))

    def pong(self):
        self.__send_payload(bytearray([
            PacketTypes.ext_pong, 0, 0, 8, 0, 0, 0, 0
        ]))
    
    def __start_msg(self, context_id, packet_type, message_length):
        self.__send_payload(bytearray([
            PacketTypes.ext_start_msg, 0, context_id, 13, 0, 0, 0, 0,
            packet_type,
            message_length & 255,
            message_length >> 8 & 255,
            message_length >> 16 & 255,
            message_length >> 24 & 255
        ]))

    def __ack(self):
        self.__send_payload(bytearray([
            PacketTypes.ext_ack,
            self.__current_packet[self.__seq_num_addr],
            self.__current_packet[self.__context_addr],
            9, 0, 0, 0, 0,
            self.__current_packet[self.__type_addr],
        ]))

    def __reject(self):
        self.__send_payload(bytearray([
            PacketTypes.ext_reject,
            self.__current_packet[self.__seq_num_addr],
            self.__current_packet[self.__context_addr],
            9, 0, 0, 0, 0,
            self.__current_packet[self.__type_addr],
        ]))

    def __noop(self):
        self.__send_payload(bytearray([
            PacketTypes.ext_noop, 0, 0, 8, 0, 0, 0, 0
        ]))

    def __end_msg(self):
        if not self.__message_context or not self.__message_type:
            return

        self.__send_payload(bytearray([
            PacketTypes.ext_end_msg,
            0,
            self.__message_context[0],
            9, 0, 0, 0, 0,
            self.__message_type[0]
        ]))

    def __resend(self):
        self.__send_payload(self.__last_payload)

    def __send_message_part(self):
        if len(self.__message_queue) == 0:
            return

        if len(self.__message_queue[0]) <= self.__pckt_len - 8:
            msg_part = self.__message_queue[0]
            self.__message_queue[0] = bytearray([])
        else:
            msg_part = self.__message_queue[0][:self.__pckt_len-8]
            self.__message_queue[0] = self.__message_queue[0][self.__pckt_len-8:]

        payload = [
            self.__message_type[0],
            self.__message_seq_num[0],
            self.__message_context[0],
            len(msg_part)+8,
            0, 0, 0, 0
        ]
        for i in msg_part:
            payload.append(i)

        self.__send_payload(bytearray(payload))
        self.__message_seq_num[0] += 1

    def __receive_message(self):
        length = self.__current_packet[self.__pckt_len_addr]
        if length < 9:
            return

        packet_type = self.__current_packet[self.__type_addr]
        context_type = self.__current_packet[self.__context_addr]
        if packet_type not in self.__buffer:
            self.__buffer[packet_type] = {}
        if context_type not in self.__buffer[packet_type]:
            self.__buffer[packet_type][context_type] = bytearray([])

        for i in range(length-8):
            self.__buffer[packet_type][context_type].append(self.__current_packet[self.__pckt_body_addr+i])

        self.__ack()

    def register_callback(self, packet_type, callback_function):
        self.__callback[packet_type] = callback_function

    def check_message(self):
        with open(self.__output_file, 'rb') as f:
            data = f.read()
            self.__current_packet = data[len(data)-self.__pckt_len:]

        if len(self.__current_packet) < 8:
            self.__current_packet = bytearray([PacketTypes.pico_noop, 0, 0, 9, 0, 0, 0, 0])

        packet_type = self.__current_packet[self.__type_addr]
        if packet_type == PacketTypes.pico_noop:
            if len(self.__message_queue) > 0 and self.__state == PicoIPCStates.noop:
                self.__start_msg(
                    self.__message_context[0],
                    self.__message_type[0],
                    len(self.__message_queue[0])
                )
                self.__state = PicoIPCStates.wait_msg_start_ack
            else:
                self.__noop()
            return

        if packet_type % 2 == 1:
            return

        crc = self.__calc_crc(packet_type)
        if crc != self.__current_packet[self.__pckt_crc_addr]:
            self.__reject()
            return

        if packet_type == PacketTypes.pico_ping or packet_type == PacketTypes.pico_pong:
            self.__buffer[packet_type] = {}
            self.__buffer[packet_type][self.__current_packet[self.__context_addr]] = bytearray([1])
        elif packet_type == PacketTypes.pico_start_msg:
            self.__state = PicoIPCStates.receive_msg_in_progress
            self.__ack()
            return
        elif packet_type == PacketTypes.pico_end_msg:
            self.__state = PicoIPCStates.noop
            self.__ack()
        elif packet_type == PacketTypes.pico_reject:
            self.__resend()
        elif packet_type == PacketTypes.pico_ack:
            if self.__state == PicoIPCStates.noop:
                self.__noop()
            if self.__state == PicoIPCStates.wait_msg_start_ack:
                self.__state = PicoIPCStates.send_msg_in_progress
            if self.__state == PicoIPCStates.send_msg_in_progress:
                if self.__message_queue and len(self.__message_queue[0]) > 0:
                    self.__send_message_part()
                else:
                    self.__end_msg()
                    self.__message_queue.pop(0)
                    self.__message_type.pop(0)
                    self.__message_context.pop(0)
                    self.__state = PicoIPCStates.noop

        if self.__state == PicoIPCStates.receive_msg_in_progress:
            self.__receive_message()

        if self.__state == PicoIPCStates.noop:
            for packet_type, messages in self.__buffer.items():
                for context, message in messages.items():
                    if packet_type in self.__callback:
                        self.__callback[packet_type](message)

            self.__buffer = {0: {0: bytearray([1])}}

    def send_message(self, message_bytes, message_type, message_context):
        self.__message_queue.append(message_bytes)
        self.__message_type.append(message_type)
        self.__message_context.append(message_context)
        self.__message_seq_num.append(0)
