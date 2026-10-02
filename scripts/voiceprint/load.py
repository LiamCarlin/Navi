import pickle, types, torch
class Dummy:
    def __init__(self, *a, **k): pass
    def __setstate__(self, s): self.__dict__["_state"] = s
class U(pickle.Unpickler):
    def find_class(self, mod, name):
        if mod.startswith(("pyannote", "lightning", "pytorch_lightning", "omegaconf")):
            return Dummy
        return super().find_class(mod, name)
pm = types.ModuleType("pm"); pm.Unpickler = U; pm.load = pickle.load
def load_state():
    ck = torch.load("pytorch_model.bin", map_location="cpu", weights_only=False, pickle_module=pm)
    return ck.get("state_dict", ck), ck
if __name__ == "__main__":
    sd, ck = load_state()
    print(type(ck), list(ck.keys())[:10] if isinstance(ck, dict) else "")
    ks = list(sd.keys()); print(len(ks)); print(ks[:4]); print(ks[-8:])
    print({k: tuple(v.shape) for k, v in sd.items() if "seg" in k})
