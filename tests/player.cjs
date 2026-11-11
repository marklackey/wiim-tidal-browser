const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync('src/wiim_tidal/static/app.js','utf8');
const elements=new Map(),storage=new Map();let tick,clock=0,requests=[],fail=false,retryTimers=false,statusFailures=0;
const context=vm.createContext({console,Intl,Map,performance:{now:()=>clock},
 localStorage:{getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v)},
 setInterval:fn=>(tick=fn,1),clearInterval:()=>{tick=null},setTimeout:fn=>{if(retryTimers)queueMicrotask(fn)},
 document:{body:{dataset:{}},querySelector(s){if(!elements.has(s))elements.set(s,{addEventListener(){},value:'',textContent:'',attrs:{},setAttribute(k,v){this.attrs[k]=v},style:{setProperty(k,v){this[k]=v}},querySelectorAll:()=>[],showModal(){this.open=true},close(){this.open=false}});return elements.get(s)}},
 fetch:async(path,options)=>{requests.push({path,options});if(fail)throw Error('Offline');if(path==='/api/now' && statusFailures>0){statusFailures--;throw Error('Offline')}return {ok:true,json:async()=>path==='/api/play'?{count:1}:path==='/api/track/123'?{album_id:999}:path==='/api/album/999'?{album:{id:999,name:'Current album'},tracks:[{id:123,title:'Actual track',artist:'Beck'}]}:path.startsWith('/api/track-resolution/')?{bits:24,hz:96000}:path==='/api/now'?{trackId:'123',title:'Actual track',artist:'Beck',sampleRate:'192000',bitRate:'4567',volume:'25',playbackStatus:'play'}:{ok:true}}}
});
vm.runInContext(source.split("$('#searchForm').onsubmit=")[0],context);
vm.runInContext("play([123],{kind:'album',title:'Sea Change',artist:'Beck'})",context);
assert.equal(requests.length,0);
clock=999;tick();assert.equal(requests.length,0);
vm.runInContext('cancelPlayback()',context);assert.equal(tick,null);assert.equal(requests.length,0);
vm.runInContext("play([123],{kind:'track',title:'Golden Age',artist:'Beck'})",context);
vm.runInContext("$('#detail').hidden=false;$('#detail').open=true",context);
clock=1999;tick();
(async()=>{
 await new Promise(r=>setImmediate(r));
 assert.equal(requests.filter(r=>r.path==='/api/play').length,1);
 assert.equal(elements.get('#detail').hidden,true,'successful playback hides duplicate selected album');
 assert.equal(elements.get('#detail').open,false);
 assert.ok(!elements.get('#currentPlayer').open,'playing should leave the track drawer collapsed');
 let recents=vm.runInContext('readRecents()',context);
 assert.equal(recents.length,1);assert.equal(recents[0].kind,'track');
 vm.runInContext("play([124],{kind:'album',title:'Sea Change',artist:'Beck'})",context);
 clock=2999;tick();await new Promise(r=>setImmediate(r));
 recents=vm.runInContext('readRecents()',context);assert.equal(recents.length,2);assert.equal(recents[0].kind,'album');
 fail=true;vm.runInContext("play([125],{kind:'track',title:'Failure'})",context);clock=3999;tick();await new Promise(r=>setImmediate(r));assert.equal(vm.runInContext('readRecents().length',context),2);
 fail=false;await vm.runInContext('now()',context);
 assert.equal(elements.get('#playingTitle').textContent,'Actual track');
 assert.match(elements.get('#playingAudio').textContent,/4567/);
 assert.equal(elements.get('#togglePlayback').textContent,'⏸');
 await new Promise(r=>setImmediate(r));
 assert.match(elements.get('#playingAudio').textContent,/24-bit \/ 96.0 kHz/);
 assert.ok(!elements.get('#playingAudio').textContent.includes('192.0'));
 vm.runInContext('updateVolume(100)',context);
 assert.equal(elements.get('#volume').style['--volume-fill'],'100%');
 vm.runInContext('updateVolume(0)',context);
 assert.equal(elements.get('#volume').style['--volume-fill'],'0%');
 await vm.runInContext("controlPlayer('volume',30)",context);
 const request=requests.find(r=>r.path==='/api/control');assert.equal(JSON.parse(request.options.body).value,30);
 assert.match(vm.runInContext("deviceAudio({sampleRate:96000,bitRate:'unknow'})",context),/Bitrate not reported/);
 vm.runInContext('showRecents()',context);
 assert.match(elements.get('#recentList').innerHTML,/card recent-card/);
 assert.match(elements.get('#recentList').innerHTML,/Sea Change/);
 await vm.runInContext("$('#currentPlayer').open=true;expandPlayingAlbum()",context);
 assert.match(elements.get('#playingTracks').innerHTML,/Current album/);
 assert.match(elements.get('#playingTracks').innerHTML,/data-track="123"/);
 assert.ok(!elements.get('#playingTracks').innerHTML.includes('>Play</button>'));
 const beforeKeys=requests.filter(r=>r.path==='/api/control').length;
 function key(key,extra={}){context.keyEvent={key,target:{closest:()=>null},preventDefault(){this.prevented=true},...extra};vm.runInContext('playbackKeydown(keyEvent)',context);return context.keyEvent}
 vm.runInContext("$('#playDialog').open=false;$('#recentDialog').open=false",context);
 for(const keyName of [' ','ArrowLeft','ArrowRight','ArrowUp','ArrowDown']){
  assert.equal(key(keyName).prevented,true);await new Promise(r=>setImmediate(r));
 }
 assert.equal(requests.filter(r=>r.path==='/api/control').length,beforeKeys+5);
 for(const extra of [{target:{closest:()=>({})}},{ctrlKey:true},{repeat:true},{isComposing:true}])assert.ok(!key(' ',extra).prevented);
 vm.runInContext("$('#recentDialog').open=true",context);assert.ok(!key(' ').prevented);
 assert.equal(requests.filter(r=>r.path==='/api/control').length,beforeKeys+5);
 vm.runInContext('updateSeek({positionMs:65000,durationMs:240000})',context);
 assert.equal(elements.get('#elapsed').textContent,'1:05');
 assert.equal(elements.get('#duration').textContent,'4:00');
 assert.equal(elements.get('#seek').disabled,false);
 vm.runInContext("$('#seek').value=90",context);
 await vm.runInContext('seekPlayback()',context);
 const seekRequest=requests.filter(r=>r.path==='/api/control').map(r=>JSON.parse(r.options.body)).find(r=>r.action==='seek');
 assert.equal(seekRequest.value,90);
 vm.runInContext('updateSeek({durationMs:0})',context);
 assert.equal(elements.get('#seek').disabled,true);
 vm.runInContext("updateSeek({positionMs:65000,durationMs:68000,playbackStatus:'play'})",context);
 const beforeTick=requests.length;
 clock+=1000;
 vm.runInContext('renderPosition()',context);
 assert.equal(elements.get('#elapsed').textContent,'1:06');
 assert.equal(requests.length,beforeTick,'local ticks must not poll the device');
 vm.runInContext("seeking=true;$('#seek').value=40;renderPosition()",context);
 assert.equal(elements.get('#seek').value,40,'clock leaves the slider alone during a seek');
 clock+=5000;
 vm.runInContext('seeking=false;renderPosition()',context);
 assert.equal(elements.get('#elapsed').textContent,'1:08','clock is capped at track duration');
 vm.runInContext("updateSeek({positionMs:2000,durationMs:68000,playbackStatus:'pause'})",context);
 clock+=1000;
 vm.runInContext('renderPosition()',context);
 assert.equal(elements.get('#elapsed').textContent,'0:02','pause freezes the latest device position');
 vm.runInContext("showDevice('192.168.1.20','Living Room')",context);
 assert.equal(elements.get('#wiimConnection').textContent,'Connecting…');
 retryTimers=true;statusFailures=3;
 const beforeConnect=requests.filter(request=>request.path==='/api/now').length;
 await vm.runInContext('now()',context);
 assert.equal(requests.filter(request=>request.path==='/api/now').length,beforeConnect+4);
 assert.equal(elements.get('#wiimConnection').textContent,'Connected');
 assert.equal(elements.get('#discoverWiim').textContent,'Find another WiiM');
 fail=true;
 await vm.runInContext('now()',context);
 assert.equal(elements.get('#wiimConnection').textContent,'Unavailable');
 assert.equal(elements.get('#discoverWiim').textContent,'Find WiiM again');
 console.log('PASS: countdown, cancel, successful-only album/track recents, current track, bitrate and controls');
})().catch(e=>{console.error(e);process.exitCode=1});
