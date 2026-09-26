import crypto from "node:crypto";
export const config={api:{bodyParser:false}};
async function rawBody(req){const c=[];for await(const x of req)c.push(Buffer.from(x));return Buffer.concat(c);}
function eq(a,b){const x=Buffer.from(a||""),y=Buffer.from(b||"");return x.length===y.length&&crypto.timingSafeEqual(x,y);}
function verify(raw,h,secret){const id=h["svix-id"],ts=h["svix-timestamp"],sig=h["svix-signature"];if(!id||!ts||!sig||!secret)return false;if(Math.abs(Date.now()/1000-Number(ts))>300)return false;const key=Buffer.from(secret.replace(/^whsec_/,""),"base64");const expected=crypto.createHmac("sha256",key).update(`${id}.${ts}.${raw.toString("utf8")}`).digest("base64");return sig.split(" ").some(p=>p.startsWith("v1,")&&eq(p.slice(3),expected));}
async function sb(path,opts={}){const base=process.env.SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!base||!key)throw new Error("server config missing");const r=await fetch(base+path,{...opts,headers:{apikey:key,Authorization:`Bearer ${key}`,"Content-Type":"application/json",...(opts.headers||{})}});if(!r.ok)throw new Error("database request failed");return r.status===204?null:r.json();}
function address(x){const m=String(x||"").toLowerCase().match(/<?([a-z0-9._+-]+)@([a-z0-9.-]+)>?$/);return m?{local:m[1],domain:m[2]}:null;}
export default async function handler(req,res){
 if(req.method!=="POST")return res.status(405).json({ok:false});
 const raw=await rawBody(req);
 if(!verify(raw,req.headers,process.env.RESEND_WEBHOOK_SECRET))return res.status(401).json({ok:false});
 let e;try{e=JSON.parse(raw.toString("utf8"));}catch{return res.status(400).json({ok:false});}
 if(e?.type!=="email.received")return res.status(200).json({ok:true,ignored:true});
 const d=e.data||{}, tos=Array.isArray(d.to)?d.to:[d.to].filter(Boolean);
 let route=null;
 for(const t of tos){const a=address(t);if(!a)continue;const q=`?select=organization_id&local_part=eq.${encodeURIComponent(a.local)}&domain=eq.${encodeURIComponent(a.domain)}&is_active=eq.true&limit=1`;const rows=await sb("/rest/v1/inbound_email_routes"+q);if(rows?.[0]){route=rows[0];break;}}
 // Unknown recipients are acknowledged but never ingested, preventing retry storms and cross-org leakage.
 if(!route)return res.status(200).json({ok:true,ignored:true,reason:"unrouted"});
 const trust=await sb("/rest/v1/rpc/get_inbound_sender_trust",{method:"POST",body:JSON.stringify({p_organization_id:route.organization_id,p_sender:String(d.from||"").slice(0,320)})});
 // Unknown or blocked senders are metadata-only/quarantined: never fetch body or attachments.
 if(trust!=="trusted")return res.status(200).json({ok:true,accepted:true,processing:false,quarantined:true});
 const providerId=String(d.email_id||d.id||e.id||"").slice(0,255);if(!providerId)return res.status(200).json({ok:true,ignored:true,reason:"missing-provider-id"});
 const rpcBody={p_organization_id:route.organization_id,p_provider:"resend",p_provider_message_id:providerId,p_sender:String(d.from||"").slice(0,320),p_subject:String(d.subject||"").slice(0,500),p_received_at:d.created_at||new Date().toISOString()};
 try{await sb("/rest/v1/rpc/ingest_inbound_email_metadata",{method:"POST",body:JSON.stringify(rpcBody)});}catch{return res.status(503).json({ok:false});}
 return res.status(202).json({ok:true,accepted:true,processing:false});
}
