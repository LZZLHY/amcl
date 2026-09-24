"""Read JVM symbolic references and declared API without initializing any classes."""
import struct
import zipfile


class Reader:
    def __init__(self, data): self.data, self.pos = data, 0
    def take(self, size):
        value = self.data[self.pos:self.pos + size]
        if len(value) != size: raise ValueError("Truncated class file")
        self.pos += size
        return value
    def u1(self): return self.take(1)[0]
    def u2(self): return struct.unpack(">H", self.take(2))[0]
    def u4(self): return struct.unpack(">I", self.take(4))[0]


def parse_class(data):
    r = Reader(data)
    if r.u4() != 0xCAFEBABE: raise ValueError("Not a class file")
    r.u2(); major = r.u2(); count = r.u2()
    cp = [None] * count; i = 1
    while i < count:
        tag = r.u1()
        if tag == 1: cp[i] = (tag, r.take(r.u2()).decode("utf-8", errors="replace"))
        elif tag in (3, 4): cp[i] = (tag, r.take(4))
        elif tag in (5, 6): cp[i] = (tag, r.take(8)); i += 1
        elif tag in (7, 8, 16, 19, 20): cp[i] = (tag, r.u2())
        elif tag in (9, 10, 11, 12, 17, 18): cp[i] = (tag, r.u2(), r.u2())
        elif tag == 15: cp[i] = (tag, r.u1(), r.u2())
        else: raise ValueError("Unknown constant pool tag " + str(tag))
        i += 1
    utf = lambda idx: cp[idx][1]
    cls = lambda idx: utf(cp[idx][1]) if idx else None
    access = r.u2(); name = cls(r.u2()); parent = cls(r.u2())
    interfaces = [cls(r.u2()) for _ in range(r.u2())]
    def attributes():
        for _ in range(r.u2()): r.u2(); r.take(r.u4())
    def members():
        out = []
        for _ in range(r.u2()):
            flags = r.u2(); member = utf(r.u2()); descriptor = utf(r.u2()); attributes()
            out.append({"name": member, "descriptor": descriptor, "access": flags})
        return out
    fields = members(); methods = members(); attributes()
    references = []
    for value in cp:
        if value and value[0] in (9, 10, 11):
            nat = cp[value[2]]
            references.append({"kind": "field" if value[0] == 9 else "method", "owner": cls(value[1]),
                               "name": utf(nat[1]), "descriptor": utf(nat[2])})
    return {"name": name, "major": major, "access": access, "parent": parent, "interfaces": interfaces,
            "fields": fields, "methods": methods, "references": references}


def jar_api(paths, java_major=21):
    result = {}
    for path in paths:
        with zipfile.ZipFile(path) as jar:
            entries = {}
            for name in jar.namelist():
                if not name.endswith(".class"): continue
                release = 0; key = name
                if name.startswith("META-INF/versions/"):
                    _, _, version, key = name.split("/", 3)
                    release = int(version)
                    if release > java_major: continue
                if key == "module-info.class": continue
                if key not in entries or entries[key][0] < release: entries[key] = (release, name)
            for _, name in entries.values():
                api = parse_class(jar.read(name))
                if api["name"] in result: raise ValueError("Duplicate runtime class: " + api["name"])
                result[api["name"]] = api
    return result


def resolve_member(api, reference, visited=None):
    visited = set() if visited is None else visited
    owner = reference["owner"]
    if owner in visited: return False
    visited.add(owner)
    node = api.get(owner)
    if not node: return False
    members = node["fields"] if reference["kind"] == "field" else node["methods"]
    def accessible(member):
        return bool(member["access"] & 1 or (member["access"] & 4 and reference.get("subclassConstructor", False)
                                            and reference["name"] == "<init>"))
    if any(m["name"] == reference["name"] and m["descriptor"] == reference["descriptor"] and accessible(m) for m in members): return True
    if reference["name"] == "<init>": return False
    for parent in [node["parent"], *node["interfaces"]]:
        if parent and resolve_member(api, {**reference, "owner": parent}, visited): return True
    return False
