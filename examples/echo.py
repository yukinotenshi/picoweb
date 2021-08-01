from lib.pico_ipc_adapter import PicoIPCAdapter, PacketTypes
from time import sleep


def main():
    ipc = PicoIPCAdapter("input.txt", "output.txt")
    ipc.register_callback(100, lambda x: print("pico says({}) {}".format(len(x), x.decode('utf-8'))))
    x = ''.join(['x' for _ in range(1000)])
    while 1:
        ipc.check_message()
        ipc.send_message(bytearray(x.encode("utf-8")), 99, 0)
        sleep(0.05)