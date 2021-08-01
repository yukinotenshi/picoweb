from lib.pico_ipc_adapter import PicoIPCAdapter, PacketTypes
from time import sleep


def main():
    ipc = PicoIPCAdapter("input.txt", "output.txt")
    ipc.register_callback(PacketTypes.pico_pong, lambda x: print("pico said pong"))
    while 1:
        ipc.check_message()
        ipc.ping()
        sleep(0.5)


