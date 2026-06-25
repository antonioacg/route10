import socket, struct, time, sys
IFACE=b'br-lan'; XID=0x13572468
CHADDR=bytes([0x02,0xde,0xad,0xbe,0xef,0x07])
def discover():
    p =struct.pack('!BBBB',1,1,6,0)+struct.pack('!I',XID)+struct.pack('!HH',0,0x8000)
    p+=b'\x00'*16+CHADDR+b'\x00'*(16-len(CHADDR))+b'\x00'*192
    p+=b'\x63\x82\x53\x63'+b'\x35\x01\x01'+b'\x37\x03\x01\x03\x06'+b'\xff'
    return p
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
try: s.setsockopt(socket.SOL_SOCKET,25,IFACE+b"\0")   # SO_BINDTODEVICE
except Exception as e: print("bindtodevice:",e)
s.bind(("0.0.0.0",68)); s.settimeout(6)
s.sendto(discover(),("255.255.255.255",67))
end=time.time()+7; got=False
while time.time()<end:
    try: data,addr=s.recvfrom(2048)
    except socket.timeout: break
    if len(data)<240 or struct.unpack("!I",data[4:8])[0]!=XID: continue
    yi=socket.inet_ntoa(data[16:20]); o=data[240:]; i=0; t=None
    while i<len(o) and o[i]!=255:
        if o[i]==0: i+=1; continue
        l=o[i+1]
        if o[i]==53: t=o[i+2]
        i+=2+l
    if t==2: print("OFFER yiaddr=%s from=%s"%(yi,addr[0])); got=True; break
print("RESULT:","ANSWERED" if got else "NO_REPLY")
sys.exit(0 if got else 1)
