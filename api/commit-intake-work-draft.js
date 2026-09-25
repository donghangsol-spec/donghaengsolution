async function body(req){if(req.body&&typeof req.body==='object')return req.body;const c=[];for await(const x of req)c.push(Buffer.from(x));try{return JSON.parse(Buffer.concat(c).toString('utf8'));}catch{return {};}}
async function sb(path,token){const base=process.env.SUPABASE_URL,key=process.env.SUPABASE_ANON_KEY;if(!base||!key)throw new Error('server config missing');const r=await fetch(base+path,{headers:{apikey:key,Authorization:'Bearer '+token}});const text=await r.text();if(!r.ok)throw Object.assign(new Error('request failed'),{status:r.status});return text?JSON.parse(text):null;}
async function service(path,payload){const base=process.env.SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!base||!key)throw new Error('server config missing');const r=await fetch(base+path,{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(payload)});const text=await r.text();if(!r.ok)throw Object.assign(new Error('commit failed'),{status:r.status});return text?JSON.parse(text):null;}
export default async function handler(req,res){
 if(req.method!=='POST')return res.status(405).json({ok:false});
 const auth=String(req.headers.authorization||'');if(!auth.startsWith('Bearer '))return res.status(401).json({ok:false});
 const token=auth.slice(7),b=await body(req),id=String(b.id||'');
 if(!/^[0-9a-f-]{36}$/i.test(id))return res.status(400).json({ok:false});
 try{
   // Approval and commit are intentionally separate actions.
   const rows=await sb('/rest/v1/intake_work_drafts?select=id,status,reviewed_by,reviewed_at,organization_id&id=eq.'+encodeURIComponent(id)+'&limit=1',token);
   const w=rows?.[0];if(!w||w.status!=='approved'||!w.reviewed_by||!w.reviewed_at)return res.status(409).json({ok:false,reason:'approval_required'});
   const entity=await service('/rest/v1/rpc/commit_intake_work_draft',{p_id:id});
   return res.status(200).json({ok:true,entity_id:entity});
 }catch(e){
   const s=e.status===401?401:e.status===403?403:409;
   return res.status(s).json({ok:false,reason:'not_committed'});
 }
}
