import struct,sys
d=open(sys.argv[1],'rb').read()
def s(b): return b.split(b'\0')[0].decode(errors='replace')
def node(o,path,depth):
    np,nc=struct.unpack_from('<II',d,o);o+=8;props={}
    for _ in range(np):
        name=s(d[o:o+32]);ln=struct.unpack_from('<I',d,o+32)[0]&0x7fffffff;o+=36
        props[name]=d[o:o+ln];o+=(ln+3)&~3
    nm=s(props.get('name',b'?'))
    comp=[x.decode(errors='replace') for x in props.get('compatible',b'').split(b'\0') if x]
    p=path+'/'+nm
    print('  '*depth+nm+('  ['+', '.join(comp)+']' if comp else ''))
    for _ in range(nc): o=node(o,p,depth+1)
    return o
node(0,'',0)
