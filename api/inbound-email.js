import crypto from "node:crypto";
export const config = { api: { bodyParser: false } };
async function rawBody(req){const chunks=[];for await(const chunk of req)chunks.push(Buffer.from(chunk));return Buffer.concat(chunks);}
function safeEqual(a,b){const aa=Buffer.from(a||"");const bb=Buffer.from(b||"");return aa.length===bb.length&&crypto.timingSafeEqual(aa,bb);}
function verify(raw,h,secret){const id=h["svix-id"],ts=h["svix-timestamp"],sig=h["svix-signature"];if(!id||!ts||!sig||!secret)return false;if(Math.abs(Date.now()/1000-Number(ts))>300)return false;const key=Buffer.from(secret.replace(/^whsec_/,""),"base64");const expected=crypto.createHmac("sha256",key).update(`${id}.${ts}.${raw.toString("utf8")}`).digest("base64");return sig.split(" ").some(p=>p.startsWith("v1,")&&safeEqual(p.slice(3),expected));}
export default async function handler(req,res){
 if(req.method!=="POST")return res.status(405).json({ok:false});
 const raw=await rawBody(req);
 if(!verify(raw,req.headers,process.env.RESEND_WEBHOOK_SECRET))return res.status(401).json({ok:false});
 let event;try{event=JSON.parse(raw.toString("utf8"));}catch{return res.status(400).json({ok:false});}
 if(event?.type!=="email.received")return res.status(200).json({ok:true,ignored:true});
 // Fail closed: do not fetch body/attachments until recipient-to-organization routing is explicit.
 return res.status(202).json({ok:true,accepted:true,processing:false});
}
