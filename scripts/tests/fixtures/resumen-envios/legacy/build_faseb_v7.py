import json, re, os, sys, datetime
# v7e (2026-10-22): pago pendiente entra con marca "(pago pendiente)" (regla David).
# v7d (2026-10-21): seccion AMAZON SELF SHIP MX aparte + modalidad real de Easy Ship desde faseA.
# v7 (2026-10-21): MELI muestra venta_panel (pack_id = numero del panel MELI); el id interno queda para decode/dedup y en comentario HTML <!-- meli_order_id=... -->.
# v4: adaptado de v3 (faseA con claves order/comprado_cdmx; Flex sin coma; atrasados MELI por dedup contra pares previos)
D=sys.argv[1]; RUN=sys.argv[2]  # RUN = etiqueta de corrida, ej "lun 19-oct"
WS=os.environ.get("FASEB_WS","/Users/gon/.openclaw/workspace-operaciones"); T=os.environ.get("FASEB_T",WS+"/packing/tmp")
A=json.load(open(f"{T}/faseA_{D}.json"))
# v7f: acepta el esquema alterno de faseA (order_id/ship_by/lista q3 con order_id; Flex con ship_by "DD Mon YYYY hh:mm AM" = franja, atrasados entran en D)
for _k in ("amazon_mx","amazon_us","amazon_flex","q3"):
    for _r in A.get(_k) or []:
        if isinstance(_r,dict):
            if "order" not in _r and "order_id" in _r: _r["order"]=_r["order_id"]
            if _k=="amazon_flex" and not _r.get("franja") and not _r.get("shipby"):
                _m=re.search(r"(\d{1,2}:\d\d [AP]M)",str(_r.get("ship_by") or ""))
                if _m and not _r.get("pago_pendiente"): _r["franja"]=_m[1]; _r["ship_by"]=None
DOW=["lun","mar","mié","jue","vie","sáb","dom"]; MON=["","ene","feb","mar","abr","may","jun","jul","ago","sep","oct","nov","dic"]
DOWF=["lunes","martes","miércoles","jueves","viernes","sábado","domingo"]; MONF=["","enero","febrero","marzo","abril","mayo","junio","julio","agosto","septiembre","octubre","noviembre","diciembre"]
EN={m:i for i,m in enumerate(["","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"])}
def fd(d): return f"{DOW[d.weekday()]} {d.day:02d}-{MON[d.month]}"
def esc(s): return s.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
dec={}
# v7b: con 0 pedidos en faseA no hace falta decode Odoo (el IN () vacio falla); si hay pedidos, el decode es obligatorio.
_nped=sum(len(A.get(k,[])) for k in("amazon_us","amazon_mx","amazon_flex","meli_por_empacar"))
_decf=f"{T}/decode_{D}.txt"
if _nped==0 and not os.path.exists(_decf): open(_decf,"w").close()
for l in open(_decf,encoding="utf-8"):
    p=l.rstrip("\n").split("|")
    if len(p)>=3 and re.match(r"^(\d{3}-\d{7}-\d{7}|\d{16})$",p[0]) and p[1] not in("MEL Distribution","Agencias Mercado Libre"):
        dec.setdefault(p[0],p[1])
MOD={"COR":"Corazon","CEN":"Centenario","VCO":"Virgen Completa","SAN":"San Benito","VBU":"Virgen Busto","PEZ":"Solo Arras"}
COL={"DOR":"Dorado","PLA":"Plateado"}
def estuche(s):
    t=set(s.split("-"))
    if "ITA" in t: return "Italia"
    if "CAO" in t: return "Caoba"
    if "CAR" in t:
        c="Rojo" if "ROJ" in t else "Azul" if "AZU" in t else "Blanco" if "BLC" in t else None
        return ("Repujado " if "REP" in t else "")+f"Carte {c}" if c else None
    if "NOG" in t: return "Nogal con ventana" if "VEN" in t else "Nogal sin ventana"
    if "BRO" in t: return "Blanco con broche"
    if "PLA" in t and "CH" in t: return "Platino CH"
    if "EUM" in t or ("EUR" in t and "VIN" in t): return ("Repujado " if "REP" in t else "")+"Europa M Vino"
    if "CHA" in t: return "Arras y Cofre con Charola"
    if "COF" in t: return "Arras y Cofre"
    return None
def dsku(sku):
    if not sku: return {}
    t=sku.split("-")
    return {"sku":sku,"modelo":next((MOD[x] for x in t if x in MOD),None),"color":COL.get(t[-1]),"estuche":estuche(sku)}
E=[]; pend=[]; pend_nombre=[]; excl_drop=[]
def add(kind,order,buyer,envio,envio_id=None,visible=None):
    d=dsku(dec.get(order)); e=dict(kind=kind,order=order,visible=visible or order,buyer=(buyer or "Sin nombre visible (pendiente de nombre)"),envio=envio,envio_id=envio_id,**d)
    if not(d.get("modelo") and d.get("color") and d.get("estuche")): pend.append(order)
    e["pers"]="PERS" in (d.get("sku") or ""); E.append(e)
DD=datetime.date.fromisoformat(D)
# v7c (2026-10-21): sin fechas escritas a mano. La fecha sale del ship-by del pedido en faseA
# (formatos: "Thu, Oct 22, 2026, 12:59 AM CST" de SC, "jue 22-oct 1:00 PM", ISO "2026-10-22");
# sin año se toma el de D (con cruce de año); si no hay ship-by legible, D.
def fecha(s):
    s=(s or "").strip()
    m=re.search(r"(\d{4})-(\d\d)-(\d\d)",s)
    if m: return datetime.date(int(m[1]),int(m[2]),int(m[3])),None
    m=re.search(r"([A-Z][a-z]{2}) (\d{1,2}), (\d{4})(?:, (\d{1,2}:\d\d [AP]M))?",s)
    if m and m[1] in EN: return datetime.date(int(m[3]),EN[m[1]],int(m[2])),m[4]
    m=re.search(r"(\d{1,2}) ([A-Z][a-z]{2}) (\d{4})(?: (\d{1,2}:\d\d [AP]M))?",s)
    if m and m[2] in EN: return datetime.date(int(m[3]),EN[m[2]],int(m[1])),m[4]
    m=re.search(r"(\d{1,2})-([a-z]{3})\w*(?: (\d{1,2}:\d\d [ap]m))?",s.lower())
    if m and m[2] in MON:
        mo=MON.index(m[2]); y=DD.year+(1 if mo-DD.month<-6 else -1 if mo-DD.month>6 else 0)
        return datetime.date(y,mo,int(m[1])),(m[3] or "").upper() or None
    return None,None
def ship_by(r): return r.get("ship_by") or r.get("shipby")
# v7e (regla David 2026-10-22): pedidos Amazon en Pendientes de SC (Payment pending / Awaiting payment
# verification), Flex incluido, van al resumen como pedidos normales por empacar con la marca "(pago pendiente)".
# Nunca se excluyen ni quedan como ghost. Senal: pago_pendiente=true en faseA o el texto de estado/cola.
PP=re.compile(r"payment\s+pending|awaiting\s+payment|pending\s+payment|pago\s+pendiente|verificaci[oó]n\s+(?:de(?:l)?\s+)?pago|pendiente\s+de\s+pago",re.I)
def pago_pend(r):
    v=r.get("pago_pendiente")
    if isinstance(v,str): v=v.strip().lower() in("true","si","sí","1","yes")
    return bool(v) or bool(PP.search(" ".join(str(r.get(k) or "") for k in("estado","estado_flex","estado_pago","cola_sc","nota","buyer"))))
def ppm(r): return " (pago pendiente)" if pago_pend(r) else ""
pago_pendientes=[]
def sc_ship(s):
    d,_=fecha(s)
    return fd(d or DD)
for r in A["amazon_us"]:
    add("self",r["order"],r["buyer"],f"{sc_ship(ship_by(r))} — Self Ship (sin recolección ni drop off; canal Amazon.com){ppm(r)}")
# v7d (2026-10-21): Self Ship MX va en su propia seccion; Easy Ship muestra la modalidad que trae faseA
# (leida del order detail: Pending Drop off / Pending Pick up, solo existe con etiqueta comprada).
# "modalidad pendiente" solo si faseA no la trae. Acepta el esquema de build_fasea.sh (source_queue/modalidad/carrier/ventana)
# y el del prompt de fase A (cola/modalidad/carrier/ventana).
def es_self_mx(r):
    q=" ".join(str(r.get(k) or "") for k in("source_queue","cola","canal_envio","modalidad")).lower()
    return "self" in q
def hora(s):
    m=re.search(r"(\d{1,2}:\d\d\s*[AP]M)(?:\s+(C[SD]T|CST6CDT|CDMX))?",s or "",re.I)
    return f"{m[1].upper()} {(m[2] or 'CST').upper()}" if m else None
def modalidad_easy(r):
    m=str(r.get("modalidad") or "").strip(); ml=m.lower()
    vent=hora(r.get("ventana")) or hora(m)
    if "drop" in ml:
        car=(r.get("carrier") or "").strip()
        if not car:
            c=re.search(r"drop ?off\s+([A-Za-z0-9]+)",m,re.I); car=c[1] if c and c[1].lower()!="ventana" else ""
        return " ".join(x for x in("drop off",car,f"ventana hasta {vent}" if vent else "") if x),False
    if "recole" in ml or "pick" in ml:
        return "recolección Easy Ship"+(f" ventana hasta {vent}" if vent else ""),False
    return "modalidad pendiente",True
easy_pend=[]
for r in A["amazon_mx"]:
    if es_self_mx(r):
        add("selfmx",r["order"],r["buyer"],f"{sc_ship(ship_by(r))} — Self Ship (sin recolección ni drop off; canal Amazon.com.mx){ppm(r)}"); continue
    mod,pe=modalidad_easy(r)
    if pe: easy_pend.append(r["order"])
    add("easy",r["order"],r["buyer"],f"{sc_ship(ship_by(r))} — {mod}{ppm(r)}")
for r in A["amazon_flex"]:
    date,hora=fecha(ship_by(r))
    if not ship_by(r) and r.get("franja"): date,hora=DD,fecha("1-ene "+r["franja"])[1]  # esquema build_fasea.sh
    if pago_pend(r) and (date is None or date<=DD):  # v7e: Flex en pago pendiente sin franja/fecha o vencido = entra en D
        if date is None or not hora: date,hora=DD,hora or "franja pendiente"
        elif date<DD: date=DD
    if date!=DD or not hora: continue
    m=[None,None,hora]
    nm=r["buyer"] if r["buyer"] and not r["buyer"].lower().startswith("sin nombre") else "Sin nombre visible en Seller Flex (pendiente de nombre)"
    if nm.startswith("Sin nombre"): pend_nombre.append(r["order"])
    add("flex",r["order"],nm,f"{fd(date)} {m[2]} — recolección Flex{ppm(r)}",r.get("envio_id"))
# dedup MELI: ya reportadas en pares/extras previos y aun sin enviar => atrasado
prev_txt=""
for f in os.listdir(WS+"/envios-del-dia"):
    if f.endswith("-meli.html") and f[:10]<D: prev_txt+=open(WS+"/envios-del-dia/"+f,encoding="utf-8").read()
for r in A["meli_por_empacar"]:
    r={**r,"venta":r.get("venta") or r.get("order"),"compra_cdmx":r.get("compra_cdmx") or r.get("compra") or r.get("comprado")}  # v7c: acepta el esquema de build_fasea.sh
    if "dropped_off" in r["estado"]: excl_drop.append(r["venta"]); continue
    m=re.match(r"(\d{4})-(\d\d)-(\d\d) (\d\d:\d\d)",r["compra_cdmx"] or "")
    env=f"comprado {fd(datetime.date(int(m[1]),int(m[2]),int(m[3])))} {m[4]}" if m else "sin fecha de envío ML"
    add("meli",r["venta"],r["buyer"],env+(" (atrasado)" if r["venta"] in prev_txt else ""),visible=r.get("venta_panel") or r["venta"])
def block(e):
    L=(["<b>PERSONALIZADA</b>",""] if e["pers"] else [])
    L+=[f"<b>Pedido:</b> {e['visible']}",f"<b>Cliente:</b> {esc(e['buyer'])}",f"<b>Modelo:</b> {e.get('modelo') or 'pendiente de producto'}",f"<b>Color:</b> {e.get('color') or 'pendiente de producto'}",f"<b>Estuche:</b> {e.get('estuche') or 'pendiente de producto'}",f"<b>SKU:</b> {e.get('sku') or 'pendiente de decode'}"]
    if e["envio_id"]: L.append(f"<b>Envío ID:</b> {e['envio_id']}")
    L.append(f"<b>Envío:</b> {e['envio']}"); return "\n".join(L)
def hblock(e):
    L=(["<b>PERSONALIZADA</b><br><br>"] if e["pers"] else [])
    fields=[("Pedido",e["visible"]),("Cliente",esc(e["buyer"])),("Modelo",e.get("modelo") or "pendiente de producto"),("Color",e.get("color") or "pendiente de producto"),("Estuche",e.get("estuche") or "pendiente de producto"),("SKU",e.get("sku") or "pendiente de decode")]
    if e["envio_id"]: fields.append(("Envío ID",e["envio_id"]))
    fields.append(("Envío",e["envio"]))
    body="".join(L)+"<br>\n    ".join(f"<b>{k}:</b> {v}" for k,v in fields)
    if e["kind"]=="meli": body=f"<!-- meli_order_id={e['order']} -->"+body
    return f'  <div style="border:1px solid #ddd;background:#fafafa;padding:10px 14px;margin-bottom:10px;">\n    {body}\n  </div>'
SEC=[("self","AMAZON SELF SHIP US"),("selfmx","AMAZON SELF SHIP MX"),("easy","AMAZON EASY SHIP"),("flex","AMAZON FLEX"),("meli","MERCADO LIBRE — POR EMPACAR")]
by={k:[e for e in E if e["kind"]==k] for k,_ in SEC}
items=[(h,block(e)) for k,h in SEC for e in by[k]]
parts=[[]]; ln=0
total=sum(len(b)+2 for _,b in items)+200
tgt=total/3
last=None
for h,b in items:
    add_h=(h!=last) or not parts[-1]
    txt=(f"<b>{h}</b>\n\n" if add_h else "")+b
    if parts[-1] and (ln+len(txt)+2>3800 or (ln>=tgt and len(parts)<3)):
        parts.append([]); ln=0; txt=f"<b>{h}</b>\n\n"+b
    parts[-1].append(txt); ln+=len(txt)+2; last=h
assert len(parts)<=50,len(parts)
# v7b (2026-10-21): partes variables. Con pocos pedidos se omiten las partes vacias (1..3 partes);
# v7c (regla David 2026-10-21): con 0 pedidos va UNA parte corta "Sin pedidos por empacar para <dia y fecha>"
# (solo Telegram a Gon e Isabel, sin mail) y sin_pedidos=true. Nunca aborta por eso.
outs=["\n\n".join(p) for p in parts if p]
SIN_TXT=f"Sin pedidos por empacar para {DOWF[DD.weekday()]} {DD.day} de {MONF[DD.month]}"
if not E: outs=[SIN_TXT]
assert all(len(o)<=3800 for o in outs),[len(o) for o in outs]
def w(path,txt):
    open(path+".part","w",encoding="utf-8").write(txt); os.replace(path+".part",path)
for f in os.listdir(T):  # quita partes viejas de una corrida previa del mismo D
    m=re.fullmatch(rf"digest_{D}_p(\d+)\.txt",f)
    if m and int(m[1])>len(outs): os.remove(f"{T}/{f}")
for i,o in enumerate(outs,1): w(f"{T}/digest_{D}_p{i}.txt",o+"\n")
partes=[f"digest_{D}_p{i}.txt" for i in range(1,len(outs)+1)]
dd=datetime.date.fromisoformat(D); title=f"Ventas para empacar — {DOWF[dd.weekday()]} {dd.day} de {MONF[dd.month]}"
def doc(sub,acc,secs,foot): return f'<!DOCTYPE html>\n<html><head><meta charset="utf-8"></head>\n<body style="margin:0;background:#f4f4f7;font-family:Arial,sans-serif;">\n<div style="max-width:640px;margin:0 auto;background:#fff;">\n  <div style="background:{acc};color:#fff;padding:18px 24px;">\n    <h1 style="margin:0;font-size:20px;">{title}</h1>\n    <p style="margin:4px 0 0;font-size:13px;color:#d5d9df;">{sub}</p>\n  </div>\n  <div style="padding:16px 24px;">\n{secs}  <p style="font-size:11px;color:#888;">{foot}</p>\n  </div>\n</div></body></html>\n'
def secs(keys,bd):
    s=""
    for k,h in SEC:
        if k in keys and by[k]: s+=f'  <h2 style="font-size:16px;border-bottom:2px solid {bd};padding-bottom:6px;">{h}</h2>\n'+"\n".join(hblock(e) for e in by[k])+"\n"
    return s
na=sum(len(by[k]) for k in("self","selfmx","easy","flex"))
mr=A["meli_resumen"]
w(f"{WS}/envios-del-dia/{D}-amazon.html",doc(f"Amazon · corrida 20h del {RUN} · fuentes: Seller Central + Seller Flex + cross-check Odoo · sin montos","#232f3e",secs(("self","selfmx","easy","flex"),"#ff9900"),f"Corrida 20h {RUN} (D={D}) · {na} órdenes Amazon ({len(by['flex'])} Flex, {len(by['easy'])} Easy Ship, {len(by['selfmx'])} Self Ship MX, {len(by['self'])} Self Ship US) · sin montos"))
w(f"{WS}/envios-del-dia/{D}-meli.html",doc(f"Mercado Libre · corrida 20h del {RUN} · fuente: API directa MELI · sin montos","#2d3277",secs(("meli",),"#ffe600"),f"Corrida 20h {RUN} (D={D}) · censo MELI directo: {len(by['meli'])} por empacar · {mr['por_confirmar']} por confirmar · {mr['alerta_48h']} alertas 48h · sin montos"))
act={r["order"] for k in("amazon_mx","amazon_us","amazon_flex") for r in A[k]}
pago_pendientes=[e["order"] for e in E if "(pago pendiente)" in e["envio"]]
q3=A["q3"]
ghosts=([(g["order"] if isinstance(g,dict) else g) for g in q3.get("ghosts",[]) if (g["order"] if isinstance(g,dict) else g) not in act] if isinstance(q3,dict) else [q["order"] for q in q3 if q["order"] not in act])
conteos={"amazon_self_us":len(by["self"]),"amazon_self_mx":len(by["selfmx"]),"amazon_easy_mx":len(by["easy"]),"amazon_flex":len(by["flex"]),"meli_por_empacar":len(by["meli"]),"meli_por_confirmar":int(mr["por_confirmar"]),"meli_alerta48h":int(mr["alerta_48h"]),"personalizadas":[e["order"] for e in E if e["pers"]],"total":len(E)}
w(f"{T}/faseB_{D}.json",json.dumps({"D":D,"ok":True,"abort":False,"conteos":conteos,"ghosts":ghosts,"meli_dropped_off_excluidas":excl_drop,"pendientes_producto":pend,"pendientes_nombre":pend_nombre,"easy_modalidad_pendiente":easy_pend,"pago_pendiente":pago_pendientes,"sin_pedidos":not E,"sin_pedidos_texto":SIN_TXT if not E else None,"partes":partes,"partes_chars":[len(o) for o in outs],"artefactos":[f"{D}-amazon.html",f"{D}-meli.html"]+partes},ensure_ascii=False,indent=1))
print([len(o) for o in outs],conteos,pend,pend_nombre)
