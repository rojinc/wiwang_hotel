#!/usr/bin/env python3
"""Dump MLO rooms / portals / entities from RSC7 .ytyp files and MLO instance placements from .ymap files.

Usage: python3 mlo_dump.py <file.ytyp|file.ymap> [...]   -> prints JSON

Pure Python, no dependencies. Follows the rage 'Meta' resource layout (as documented by CodeWalker).
Only the fields needed for scripting (names, positions, rotations, room bounds, portal links) are decoded.
"""
import sys, zlib, struct, json

def joaat(s):
    h = 0
    for c in s.lower().encode():
        h = (h + c) & 0xffffffff
        h = (h + (h << 10)) & 0xffffffff
        h ^= h >> 6
    h = (h + (h << 3)) & 0xffffffff
    h ^= h >> 11
    h = (h + (h << 15)) & 0xffffffff
    return h

# Meta struct / field name hashes. Most are joaat() of the symbol; the others are fixed rage hashes.
H2N = {joaat(n): n for n in ['name', 'flags', 'guid', 'position', 'rotation', 'entities', 'rooms', 'portals', 'corners',
                             'locations', 'extensions', 'archetypes', 'scaleXY', 'scaleZ', 'lodDist', 'parentIndex']}
H2N.update({0xD98BB561: 'CMapTypes', 0xD3593FA6: 'CMapData', 0x10506455: 'CMloArchetypeDef', 0x82D6FC83: 'CBaseArchetypeDef',
            0x0B1811F1: 'CMloRoomDef', 0x995072CA: 'CMloPortalDef', 0xD6A799F9: 'CMloEntitySet', 0xCE501483: 'CEntityDef',
            0x09CC28BE: 'CMloInstanceDef', 0xA023A02C: 'archetypeName', 0xD9EF8236: 'bbMin', 0xE78AA618: 'bbMax',
            0xF470D2FD: 'roomFrom', 0x9B649621: 'roomTo', 0x8E05312C: 'attachedObjects', 0x45BCB930: 'entitySets',
            0x53DF8649: 'defaultEntitySets'})
def nm(h): return H2N.get(h, '0x%08X' % h)

class Meta:
    def __init__(self, buf):
        self.b = buf
        hdr = struct.unpack_from('<IIQIIIIQQQQQHHHH', buf, 0)
        tag, sptr, eptr, dptr, scount, ecount, dcount = hdr[3], hdr[7], hdr[8], hdr[9], hdr[12], hdr[13], hdr[14]
        assert tag == 0x50524430, 'not a Meta resource'
        self.structs = {}
        for i in range(scount):
            o = self.abs(sptr) + i * 32
            sh, key, u8, uc, entptr, ssize, u1c, ecnt = struct.unpack_from('<IIIIQIHH', buf, o)
            fields = {}
            for j in range(ecnt):
                eh, doff, dtype, u9, refidx, refkey = struct.unpack_from('<IiBBHI', buf, self.abs(entptr) + j * 16)
                fields[nm(eh)] = doff
            self.structs[nm(sh)] = {'size': ssize, 'fields': fields}
        self.blocks = []
        for i in range(dcount):
            bh, blen, bptr = struct.unpack_from('<IiQ', buf, self.abs(dptr) + i * 16)
            self.blocks.append({'name': nm(bh), 'len': blen, 'off': self.abs(bptr)})

    @staticmethod
    def abs(ptr):  # resource pointer (0x5XXXXXXX = system segment)
        return ptr & 0x0FFFFFFF

    def mptr(self, raw):  # Meta data pointer: 12-bit 1-based block id + 20-bit offset
        d1 = raw & 0xFFFFFFFF
        blk, o = d1 & 0xFFF, (d1 >> 12) & 0xFFFFF
        return None if blk == 0 else self.blocks[blk - 1]['off'] + o

    def block_at(self, off):
        for b in self.blocks:
            if b['off'] <= off < b['off'] + b['len']:
                return b

    def f(self, sname, base, field): return base + self.structs[sname]['fields'][field]
    def u32(self, o): return struct.unpack_from('<I', self.b, o)[0]
    def u64(self, o): return struct.unpack_from('<Q', self.b, o)[0]
    def v3(self, o): return list(struct.unpack_from('<fff', self.b, o))
    def v4(self, o): return list(struct.unpack_from('<ffff', self.b, o))
    def cstr(self, o):
        p = self.mptr(self.u64(o))
        if p is None: return ''
        return self.b[p:self.b.index(b'\0', p)].decode()
    def arr(self, o):  # Array_*: pointer(8) count(2) capacity(2)
        ptr, cnt = struct.unpack_from('<QH', self.b, o)
        return self.mptr(ptr), cnt
    def u32s(self, o):
        p, c = self.arr(o); return [self.u32(p + 4 * i) for i in range(c)] if p is not None else []
    def struct_ptrs(self, o):
        p, c = self.arr(o); return [self.mptr(self.u64(p + 8 * i)) for i in range(c)] if p is not None else []

    def entity(self, off):
        blk = self.block_at(off)
        sn = blk['name'] if blk and blk['name'] in self.structs else 'CEntityDef'
        e = {'struct': sn, 'archetypeHash': self.u32(self.f(sn, off, 'archetypeName')), 'flags': self.u32(self.f(sn, off, 'flags')),
             'position': self.v3(self.f(sn, off, 'position')), 'rotation': self.v4(self.f(sn, off, 'rotation'))}
        if sn == 'CMloInstanceDef':
            e['defaultEntitySets'] = self.u32s(self.f(sn, off, 'defaultEntitySets'))
        return e

def dump_ytyp(buf):
    m = Meta(buf); out = []
    for b in m.blocks:
        if b['name'] != 'CMloArchetypeDef': continue
        sn = 'CMloArchetypeDef'; size = m.structs[sn]['size']
        for k in range(b['len'] // size):
            base = b['off'] + k * size
            a = {'nameHash': m.u32(m.f(sn, base, 'name')), 'bbMin': m.v3(m.f(sn, base, 'bbMin')), 'bbMax': m.v3(m.f(sn, base, 'bbMax'))}
            a['entities'] = [m.entity(p) for p in m.struct_ptrs(m.f(sn, base, 'entities'))]
            rp, rc = m.arr(m.f(sn, base, 'rooms')); rs = m.structs['CMloRoomDef']['size']
            a['rooms'] = [{'index': i, 'name': m.cstr(m.f('CMloRoomDef', rp + i * rs, 'name')),
                           'bbMin': m.v3(m.f('CMloRoomDef', rp + i * rs, 'bbMin')), 'bbMax': m.v3(m.f('CMloRoomDef', rp + i * rs, 'bbMax')),
                           'attachedObjects': m.u32s(m.f('CMloRoomDef', rp + i * rs, 'attachedObjects'))} for i in range(rc)]
            pp, pc = m.arr(m.f(sn, base, 'portals')); ps = m.structs['CMloPortalDef']['size']; portals = []
            for i in range(pc):
                po = pp + i * ps
                cp, cc = m.arr(m.f('CMloPortalDef', po, 'corners'))
                portals.append({'index': i, 'roomFrom': m.u32(m.f('CMloPortalDef', po, 'roomFrom')), 'roomTo': m.u32(m.f('CMloPortalDef', po, 'roomTo')),
                                'flags': m.u32(m.f('CMloPortalDef', po, 'flags')),
                                'corners': [m.v4(cp + 16 * j)[:3] for j in range(cc)] if cp is not None else [],
                                'attachedObjects': m.u32s(m.f('CMloPortalDef', po, 'attachedObjects'))})
            a['portals'] = portals
            sets = []
            if 'CMloEntitySet' in m.structs:
                sp, sc = m.arr(m.f(sn, base, 'entitySets')); ss = m.structs['CMloEntitySet']['size']
                for i in range(sc):
                    so = sp + i * ss
                    sets.append({'nameHash': m.u32(m.f('CMloEntitySet', so, 'name')), 'locations': m.u32s(m.f('CMloEntitySet', so, 'locations')),
                                 'entities': [m.entity(p) for p in m.struct_ptrs(m.f('CMloEntitySet', so, 'entities'))]})
            a['entitySets'] = sets
            out.append(a)
    return out

def dump_ymap(buf):
    m = Meta(buf); out = {'entities': []}
    for b in m.blocks:
        if b['name'] != 'CMapData': continue
        out['nameHash'] = m.u32(m.f('CMapData', b['off'], 'name'))
        out['entities'] = [m.entity(p) for p in m.struct_ptrs(m.f('CMapData', b['off'], 'entities'))]
    return out

def load(path):
    raw = open(path, 'rb').read()
    assert raw[:4] == b'RSC7', 'not an RSC7 resource'
    return zlib.decompress(raw[16:], -15)

if __name__ == '__main__':
    res = {}
    for path in sys.argv[1:]:
        buf = load(path)
        res[path] = dump_ytyp(buf) if path.endswith('.ytyp') else dump_ymap(buf)
    print(json.dumps(res, indent=1))
