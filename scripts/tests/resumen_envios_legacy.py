#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    fixture = root / "scripts" / "tests" / "fixtures" / "resumen-envios" / "legacy"
    with tempfile.TemporaryDirectory(prefix="resumen-envios-legado-") as directory:
        work = Path(directory)
        tmp = work / "tmp"
        ws = work / "ws"
        tmp.mkdir()
        (ws / "envios-del-dia").mkdir(parents=True)
        shutil.copy(fixture / "faseA_2026-11-19.json", tmp)
        shutil.copy(fixture / "decode_2026-11-19.txt", tmp)
        env = dict(os.environ, FASEB_WS=str(ws), FASEB_T=str(tmp))
        subprocess.run(
            [sys.executable, str(fixture / "build_faseb_v7.py"), "2026-11-19", "ensayo"],
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        result = json.loads((tmp / "faseB_2026-11-19.json").read_text(encoding="utf-8"))
        text = "\n".join((tmp / name).read_text(encoding="utf-8") for name in result["partes"])
        block = next(block for block in text.split("\n\n") if "702-0000000-0000004" in block)
        observed = {
            "ml_por_confirmar_contado": result["conteos"]["meli_por_confirmar"] == 1,
            "ml_por_confirmar_visible": "2000000000000098" in text,
            "fecha_ilegible_sustituida_por_corte": "jue 19-nov" in block,
            "partes": len(result["partes"]),
        }
        expected = {
            "ml_por_confirmar_contado": True,
            "ml_por_confirmar_visible": False,
            "fecha_ilegible_sustituida_por_corte": True,
            "partes": 3,
        }
        if observed != expected:
            print(json.dumps({"estado": "FALLO", "observado": observed}, ensure_ascii=False))
            return 1
        print(json.dumps({"estado": "COMPARACION_REPRODUCIDA", **observed}, ensure_ascii=False))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
