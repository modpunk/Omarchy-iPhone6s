import struct,sys,re
d=open(sys.argv[1],'rb').read(); want=sys.argv[2:]
def s(b): return b.split(b'\0')[0].decode(errors='replace')
def show(v):
    if len(v)<=64 and all(32<=c<127 or c==0 for c in v) and v[:1]!=b'\0' and b'\0' in v+b'\0': return repr(v.rstrip(b'\0').decode())
    return v[:48].hex()+('…(%d)'%len(v) if len(v)>48 else '')
def node(o,path):
    np,nc=struct.unpack_from('<II',d,o);o+=8;props=[]
    for _ in range(np):
        name=s(d[o:o+32]);ln=struct.unpack_from('<I',d,o+32)[0]&0x7fffffff;o+=36
        props.append((name,d[o:o+ln]));o+=(ln+3)&~3
    nm=s(dict(props).get('name',b'?')); p=path+'/'+nm
    if any(p.endswith('/'+w) for w in want):
        print('==',p)
        for k,v in props: print('   %-28s %s'%(k,show(v)))
    for _ in range(nc): o=node(o,p)
    return o
node(0,'')
