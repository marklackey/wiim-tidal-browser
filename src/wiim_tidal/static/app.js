
const $=s=>document.querySelector(s);
let results = {artist: [], album: [], track: []};
let active = null;
const matchLabels = {artist: 'Artist matches', album: 'Album matches', track: 'Track matches'};
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function msg(s,error=false){$('#status').textContent=s;$('#status').className='status'+(error?' error':'')}
async function api(path, options) {
    if (options?.method === 'POST') {
        options = {...options, headers: {...options.headers, 'Content-Type': 'application/json',
            'X-Local-Token': $('meta[name="local-token"]').content || ''}, body: options.body ?? '{}'};
    }
    const response = await fetch(path, options);
    const data = await response.json();
    if (!response.ok) throw Error(data.error || 'HTTP ' + response.status);
    return data;
}
const resolutionCache=new Map();let resolutionObserver=null,drawVersion=0;
const sectionState=new Map();
let resultQuery = '';
function setSectionsOpen(open){$('#results').querySelectorAll('details[data-section]').forEach(section=>{section.open=open;sectionState.set(section.dataset.section,open)})}
const qualityTiers=['Hi-Res Lossless','Lossless','Compressed','Unknown'];
const collator=new Intl.Collator(undefined,{sensitivity:'base',numeric:true});
function qualityTier(a){const labels=[a.quality,...(a.tags||[])].map(x=>String(x).toUpperCase().replace(/[^A-Z0-9]/g,''));if(labels.some(x=>x==='HIRESLOSSLESS'||x==='HIRES'))return 0;if(labels.includes('LOSSLESS'))return 1;if(labels.some(x=>['HIGH','LOW','AAC','MP3'].includes(x)))return 2;return 3}
function qualityBadges(a){
    const tier=qualityTier(a),label=tier<2?qualityTiers[tier]:a.quality;
    const normalize=value=>String(value).toUpperCase().replace(/[^A-Z0-9]/g,'');
    const seen=new Set([normalize(label)]);
    const tags=(a.tags||[]).filter(tag=>{const key=normalize(tag);if(seen.has(key)||(tier<2&&['LOSSLESS','HIRES','HIRESLOSSLESS'].includes(key)))return false;seen.add(key);return true});
    return [label,...tags].map(tag=>`<span class="pill">${esc(tag)}</span>`).join('');
}
function resultAlbum(record) {
    return record.album ?? record.name;
}

function filteredResults(ignoreAlbum = false, ignoreArtist = false) {
    const artist = ignoreArtist ? '' : $('#artistFilter').value;
    const album = ignoreAlbum ? '' : $('#albumFilter').value;
    return Object.values(results).flat().filter(record =>
        (!artist || record.artist === artist) && (!album || resultAlbum(record) === album)
        && (!$('#hiResOnly').checked || qualityTier(record) === 0));
}

function populateAlbumFilters(reset = false) {
    const artist = $('#artistFilter'), album = $('#albumFilter');
    const selectedArtist = reset ? '' : artist.value;
    const selectedAlbum = reset ? '' : album.value;
    const artists = [...new Set(filteredResults(true, true).map(record => record.artist))].sort(collator.compare);
    artist.innerHTML = '<option value="">All artists</option>' + artists.map(name =>
        `<option value="${esc(name)}">${esc(name)}</option>`).join('');
    artist.value = artists.includes(selectedArtist) ? selectedArtist : '';
    const albums = [...new Set(filteredResults(true).map(resultAlbum).filter(Boolean))].sort(collator.compare);
    album.innerHTML = '<option value="">All albums</option>' + albums.map(name =>
        `<option value="${esc(name)}">${esc(name)}</option>`).join('');
    album.value = albums.includes(selectedAlbum) ? selectedAlbum : '';
}

function coverArt(art) {
    const image = art ? `<img class="cover" loading="lazy" src="${esc(art)}" alt="">` : '';
    return `<span class="cover-wrap" aria-hidden="true">♫${image}</span>`;
}

function resolutionText(r){return `${r.bits}-bit / ${(r.hz/1000).toFixed(1)} kHz (first-track estimate)`}
function fetchResolution(id){id=String(id);if(!resolutionCache.has(id)){const pending=api('/api/resolution/'+id).catch(e=>{resolutionCache.delete(id);throw e});resolutionCache.set(id,pending)}return resolutionCache.get(id)}
function albumCard(album) {
    const meta = [album.artist, album.year, album.version].filter(Boolean).map(esc).join(' · ');
    return `<article class="card" data-id="${album.id}" data-quality="${qualityTier(album)}">
        <button type="button" class="card-main" aria-label="View ${esc(album.name)} by ${esc(album.artist)}">
            ${coverArt(album.art)}
            <span class="title" title="${esc(album.name)}">${esc(album.name)}</span>
            <span class="sub">${meta}</span>
            <span class="tags">${qualityBadges(album)}</span>
        </button>
        <p class="muted" data-resolution>Checking resolution when visible</p>
    </article>`;
}

function searchKey(value) {
    return String(value ?? '').normalize('NFKC').trim().replace(/\s+/g, ' ').toLowerCase();
}

function chronological(a, b) {
    const date = record => record.releaseDate || (record.year ? String(record.year) : '');
    const first = date(a), second = date(b);
    if (Boolean(first) !== Boolean(second)) return first ? -1 : 1;
    return collator.compare(first, second)
        || collator.compare(resultAlbum(a), resultAlbum(b))
        || (a.number || 0) - (b.number || 0)
        || collator.compare(a.title || a.name, b.title || b.name)
        || a.id - b.id;
}

function searchTrackCard(track) {
    return `<div class="search-track">
        <button type="button" class="track" data-search-track="${track.id}" aria-label="Play ${esc(track.title)}">
            <span class="track-icon" aria-hidden="true">▶</span>
            <span>${esc(track.title)}<small class="sub">${esc(track.album)}</small></span>
        </button>
        ${track.album_id ? `<button class="ghost" type="button" data-open-album="${track.album_id}">View album</button>` : ''}
    </div>`;
}

function artistGroups(records, kind, tier, query) {
    const groups = new Map();
    for (const record of records) {
        const key = searchKey(record.artist);
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(record);
    }

    return [...groups.entries()]
        .sort(([a, first], [b, second]) => Number(b === query) - Number(a === query)
            || collator.compare(first[0].artist, second[0].artist))
        .map(([name, items]) => {
            const artist = items[0].artist;
            const sectionKey = esc(JSON.stringify([kind, tier, name]));
            const isTrack = kind === 'track';
            const content = items.sort(chronological).map(isTrack ? searchTrackCard : albumCard).join('');
            return `<details class="result-section artist-section" data-section="${sectionKey}">
                <summary>${esc(artist)} · ${items.length}</summary>
                <div class="${isTrack ? 'search-tracks' : 'cards'}">${content}</div></details>`;
        }).join('');
}

function draw() {
    const version = ++drawVersion;
    if (resolutionObserver) resolutionObserver.disconnect();
    const show = new Set(filteredResults());
    const query = searchKey(resultQuery);
    const html = Object.entries(matchLabels).map(([kind, title]) => {
        const records = results[kind].filter(record => show.has(record));
        if (!records.length) return '';
        const tiers = qualityTiers.map((quality, tier) => {
            const items = records.filter(record => qualityTier(record) === tier);
            if (!items.length) return '';
            return `<details class="result-section quality-section" data-section="${kind}-quality-${tier}" data-tier="${tier}">
                <summary>${quality} · ${items.length}</summary>
                <div class="quality-content">${artistGroups(items, kind, tier, query)}</div></details>`;
        }).join('');
        return `<details class="result-section match-section" data-section="${kind}">
            <summary>${title} · ${records.length}</summary>
            <div class="match-content">${tiers}</div></details>`;
    }).join('');
    const filtered = Boolean($('#artistFilter').value || $('#albumFilter').value || $('#hiResOnly').checked);
    const total = Object.values(results).reduce((count, records) => count + records.length, 0);
    const count = `${show.size} ${show.size === 1 ? 'match' : 'matches'}`;
    $('#resultCount').textContent = filtered ? `${show.size} of ${total} matches` : count;
    $('#resetFilters').hidden = !filtered;
    $('#resultControls').hidden = !total;
    $('#groupActions').hidden = !show.size;
    $('#results').innerHTML = html || (filtered
        ? '<p class="empty">No matches with these filters. Clear the filters to see all results.</p>'
        : '<p class="empty">No matches. Try a different search or select another category.</p>');
    $('#results').querySelectorAll('details[data-section]').forEach(section => {
        const key = section.dataset.section;
        let lastOpen = sectionState.get(key) ?? (section.parentElement.childElementCount === 1);
        section.open = lastOpen;
        section.ontoggle = () => {
            if (version !== drawVersion || section.open === lastOpen) return;
            lastOpen = section.open;
            sectionState.set(key, lastOpen);
        };
    });
    const tracks = new Map(results.track.map(track => [String(track.id), track]));
    $('#results').querySelectorAll('[data-search-track]').forEach(button => {
        button.onclick = () => {
            const track = tracks.get(button.dataset.searchTrack);
            play([track.id], {kind:'track', title:track.title, artist:track.artist, albumId:track.album_id}, [track]);
        };
    });
    $('#results').querySelectorAll('[data-open-album]').forEach(button => {
        button.onclick = () => openAlbum(button.dataset.openAlbum);
    });
    // One background lookup at a time so stream requests do not flood TIDAL.
    const queue=[];let running=false;
    async function drain(){if(running)return;running=true;try{while(queue.length&&version===drawVersion){const card=queue.shift();if(!card.isConnected)continue;if(card.getClientRects&&!card.getClientRects().length){resolutionObserver.observe(card);continue;}const label=card.querySelector('[data-resolution]');label.textContent='Checking resolution…';try{const r=await fetchResolution(card.dataset.id);if(card.isConnected)label.textContent=resolutionText(r)}catch(e){if(card.isConnected){label.textContent='Resolution unavailable';label.title=e.message}}}}finally{running=false}}
    resolutionObserver=new IntersectionObserver(entries=>{for(const entry of entries){if(entry.isIntersecting){resolutionObserver.unobserve(entry.target);queue.push(entry.target)}}drain()},{rootMargin:'150px'});
    $('#results').querySelectorAll('[data-id]').forEach(card => {
        card.querySelector('button').onclick = () => openAlbum(card.dataset.id);
        resolutionObserver.observe(card);
    });
}
function trackRows(data) {
    return data.tracks.map((track, i) => {
        const current = String(track.id) === currentTrackId;
        return `<button type="button" class="track${current ? ' current' : ''}" data-track="${track.id}"
            ${current ? 'aria-current="true"' : ''} aria-label="Play ${esc(track.title)}">
            <span class="muted">${i + 1}</span>
            <span>${esc(track.title)}<small class="sub">${esc(track.artist)}</small></span>
            <span class="track-icon" aria-hidden="true">▶</span>
        </button>`;
    }).join('');
}

function bindTrackRows(panel, data) {
    panel.querySelectorAll('[data-track]').forEach(button => {
        button.onclick = () => {
            const track = data.tracks.find(item => item.id === Number(button.dataset.track));
            play([track.id], {
                kind: 'track', title: track.title, artist: track.artist,
                albumId: data.album.id, art: data.album.art,
            }, data.tracks);
        };
    });
}

let albumRequest = 0;
function closeAlbum() {
    const dialog = $('#detail');
    if (dialog.open) dialog.close();
    dialog.hidden = true;
}

async function openAlbum(id) {
    const token = ++albumRequest;
    msg('Loading album…');
    try {
        const data = await api('/api/album/' + id);
        if (token !== albumRequest) return;
        active = data;
        const album = data.album;
        const meta = [album.artist, album.year, album.quality, `${data.tracks.length} tracks`]
            .filter(Boolean).map(esc).join(' · ');
        const panel = $('#albumContent');
        panel.innerHTML = `<div class="dialog-body">
            <div class="dialog-top"><button id="closeAlbum" class="secondary" type="button">Close album</button></div>
            <div class="album-header">
                ${coverArt(album.art)}
                <div><h2 id="albumTitle">${esc(album.name)}</h2><p class="sub">${meta}</p></div>
            </div>
            <div class="album-actions">
                <button id="all" type="button">Play album on WiiM</button>
                <a href="${esc(album.url)}" target="_blank" rel="noopener">Open in TIDAL ↗</a>
            </div>
            <div>${trackRows(data)}</div>
        </div>`;
        $('#closeAlbum').onclick = closeAlbum;
        $('#all').onclick = () => play(data.tracks.map(track => track.id), {
            kind: 'album', title: album.name, artist: album.artist, albumId: album.id, art: album.art,
        }, data.tracks);
        bindTrackRows(panel, data);
        const dialog = $('#detail');
        dialog.hidden = false;
        if (!dialog.open) dialog.showModal();
        msg('');
    } catch (error) {
        if (token === albumRequest) msg(error.message, true);
    }
}

const RECENTS_KEY = 'wiim-play-recents-v1';
let pendingPlay = null, playTimer = null, submitting = false, lastQueue = null;
let searched = false;

function readRecents() {
    try {
        const items = JSON.parse(localStorage.getItem(RECENTS_KEY) || '[]');
        return Array.isArray(items) ? items.filter(item =>
            item && ['album', 'track'].includes(item.kind) && typeof item.title === 'string' &&
            typeof item.at === 'string').slice(0, 100) : [];
    } catch {
        return [];
    }
}

function recordRecent(entry) {
    try {
        const item = {...entry, at: new Date().toISOString()};
        localStorage.setItem(RECENTS_KEY, JSON.stringify([item, ...readRecents()].slice(0, 100)));
    } catch {
        return;
    }
    drawRecentShelf();
}

function bindRecents(container, items, fromDialog = false) {
    container.querySelectorAll('[data-recent]').forEach(button => {
        button.onclick = () => {
            if (fromDialog) $('#recentDialog').close();
            openAlbum(items[Number(button.dataset.recent)].albumId);
        };
    });
}

function drawRecentShelf() {
    const seen = new Set();
    const items = readRecents().filter(item => {
        if (!item.albumId || seen.has(item.albumId)) return false;
        seen.add(item.albumId);
        return true;
    }).slice(0, 4);
    $('#homeRecents').hidden = searched || !items.length;
    if ($('#homeRecents').hidden) return;
    const shelf = $('#recentShelf');
    shelf.innerHTML = items.map((item, i) => `<article class="card">
        <button type="button" class="card-main" data-recent="${i}">
            ${coverArt(item.art)}<span class="title">${esc(item.title)}</span><span class="sub">${esc(item.artist)}</span>
        </button>
    </article>`).join('');
    bindRecents(shelf, items);
}

function showRecents() {
    const items = readRecents();
    const list = $('#recentList');
    list.innerHTML = items.length ? items.map((item, i) => `<button type="button"
        class="card recent-card" data-recent="${i}" ${item.albumId ? '' : 'disabled'}>
        ${coverArt(item.art)}
        <span class="recent-copy"><strong class="title">${esc(item.title)}</strong>
        <span class="sub">${esc(item.artist)}</span>
        <span class="sub">${item.kind === 'album' ? 'Album' : 'Track'} · ${esc(new Date(item.at).toLocaleString())}</span></span>
    </button>`).join('') : '<p class="empty">Albums and tracks you play on your WiiM will appear here.</p>';
    bindRecents(list, items, true);
    $('#recentDialog').showModal();
}
function cancelPlayback(){if(submitting)return;if(playTimer!==null)clearInterval(playTimer);playTimer=null;pendingPlay=null;$('#playDialog').close()}
function play(ids,entry,tracks=active?.tracks||[]){
    if(submitting)return;cancelPlayback();pendingPlay={ids:[...ids],entry:{...entry},tracks:tracks.filter(t=>ids.includes(t.id))};
    $('#playHeading').textContent='Starting playback';$('#playDescription').textContent=entry.title;$('#playStatus').textContent='Starts in 1 second and replaces the WiiM queue.';$('#cancelPlay').disabled=false;$('#cancelPlay').textContent='Cancel';$('#playProgress').value=0;$('#playDialog').showModal();
    const started=performance.now();playTimer=setInterval(()=>{const elapsed=performance.now()-started;$('#playProgress').value=Math.min(100,elapsed/10);if(elapsed>=1000){clearInterval(playTimer);playTimer=null;submitPlayback()}},25);
}
async function submitPlayback() {
    const pending = pendingPlay;
    if (!pending) return;
    pendingPlay = null;
    submitting = true;
    $('#cancelPlay').disabled = true;
    $('#playStatus').textContent = 'Sending queue to WiiM…';
    try {
        const result = await api('/api/play', {method:'POST', body:JSON.stringify({ids:pending.ids})});
        lastQueue = pending;
        recordRecent(pending.entry);
        $('#playDialog').close();
        closeAlbum();
        ++albumRequest;
        playingAlbumKey = '';
        if ($('#currentPlayer').open) expandPlayingAlbum();
        msg(result.count === 1 ? 'Track sent to WiiM.' : `${result.count} tracks sent to WiiM.`);
        setTimeout(now, 1200);
    } catch (error) {
        $('#playHeading').textContent = 'Playback failed';
        $('#playStatus').textContent = error.message;
        $('#cancelPlay').textContent = 'Close';
    } finally {
        submitting = false;
        $('#cancelPlay').disabled = false;
    }
}
const trackResolutionCache=new Map();let currentTrackId='';
function deviceAudio(m,resolution){
    const parts=[];
    if(resolution)parts.push(`${resolution.bits}-bit / ${(resolution.hz/1000).toFixed(1)} kHz`);
    else parts.push('Track resolution unavailable');
    const rate=m.bitRate??m.bitrate??m.bit_rate;
    if(Number(rate)>0)parts.push(`Bitrate: ${rate}${m.bitrateUnit?' '+m.bitrateUnit:''}`);
    else parts.push('Bitrate not reported by WiiM');
    return parts.join(' · ');
}
function loadTrackResolution(id,m){
    if(!/^[1-9][0-9]*$/.test(id))return;
    if(!trackResolutionCache.has(id))trackResolutionCache.set(id,api('/api/track-resolution/'+id).catch(error=>{trackResolutionCache.delete(id);throw error}));
    trackResolutionCache.get(id).then(res=>{if(currentTrackId===id)$('#playingAudio').textContent=deviceAudio(m,res)}).catch(()=>{});
}
const transportButtons = ['#previousTrack', '#togglePlayback', '#nextTrack'];
let transportReady = false, controlBusy = false;

function setTransportReady(ready) {
    transportReady = ready;
    transportButtons.forEach(selector => { $(selector).disabled = !ready || controlBusy; });
}

let statusRequest = null;
let deviceRevision = 0;

function now(afterCurrent = false) {
    if (serverStopped) return;
    const revision = deviceRevision;
    if (statusRequest?.revision === revision) {
        return afterCurrent === true ? statusRequest.promise.then(() => now()) : statusRequest.promise;
    }
    const promise = refreshPlayer(revision).finally(() => {
        if (statusRequest?.promise !== promise) return;
        statusRequest = null;
        $('#refresh').disabled = serverStopped;
    });
    statusRequest = {revision, promise};
    return promise;
}

async function readPlayerStatus(revision) {
    const delays = deviceSelected && wiimConnectionState !== 'error' ? [0, 750, 1500, 3000] : [0];
    for (const [index, delay] of delays.entries()) {
        if (delay) await new Promise(resolve => setTimeout(resolve, delay));
        if (revision !== deviceRevision || serverStopped) return;
        try {
            return await api('/api/now');
        } catch (error) {
            if (index === delays.length - 1) throw error;
            if (revision !== deviceRevision || serverStopped) return;
            if (wiimConnectionState === 'ready') {
                showWiimConnection('checking', 'Reconnecting…');
            }
        }
    }
}

async function refreshPlayer(revision) {
    $('#refresh').disabled = true;
    try {
        const metadata = await readPlayerStatus(revision);
        if (!metadata || revision !== deviceRevision || serverStopped) return;
        updateTransport(metadata);
        const controlsAvailable = metadata.controlsAvailable !== false;
        setTransportReady(controlsAvailable);
        showWiimConnection('ready', 'Connected');
        $('#wiimConnectionHelp').textContent = '';
        const id = String(metadata.trackId || metadata.track_id || '');
        if (currentTrackId !== id) playingAlbumKey = '';
        currentTrackId = id;
        if ($('#currentPlayer').open) expandPlayingAlbum();
        const queued = lastQueue?.tracks.find(track => String(track.id) === id);
        const title = metadata.title && metadata.title !== 'unknow' ? metadata.title : queued?.title;
        $('#playingTitle').textContent = title || (metadata.playbackStatus === 'play'
            ? 'Track details unavailable' : 'No track details');
        $('#playingArtist').textContent = [
            metadata.artist && metadata.artist !== 'unknow' ? metadata.artist : queued?.artist,
            metadata.album,
        ].filter(Boolean).join(' · ');
        $('#playingAudio').textContent = title ? deviceAudio(metadata) : '';
        if (title) loadTrackResolution(id, metadata);
        const art = metadata.albumArtURI || metadata.albumArtUrl || (queued ? lastQueue.entry.art : null);
        const image = $('#playingArt');
        if (art && image.getAttribute?.('src') !== art) image.src = art;
        image.hidden = !art;
        $('#now').textContent = 'Updated ' + new Date().toLocaleTimeString();
        $('#playingState').textContent = !controlsAvailable ? 'Controls unavailable'
            : metadata.playbackStatus === 'pause' ? 'Paused'
            : metadata.playbackStatus === 'stop' ? 'Stopped'
            : metadata.playbackStatus === 'play' ? 'Now playing on WiiM' : 'WiiM playback';
    } catch (error) {
        if (revision !== deviceRevision || serverStopped) return;
        currentTrackId = '';
        playingAlbumKey = '';
        ++playingAlbumRequest;
        $('#playingTracks').textContent = 'Playback information is unavailable.';
        setTransportReady(false);
        showWiimConnection(deviceSelected ? 'error' : '', deviceSelected ? 'Unavailable' : 'Not selected');
        updateSeek({});
        $('#seek').disabled = true;
        $('#volume').disabled = true;
        $('#volumeValue').textContent = '—';
        $('#playingState').textContent = 'WiiM playback';
        $('#playingTitle').textContent = deviceSelected ? 'WiiM unavailable' : 'Select your WiiM in Setup';
        $('#playingArtist').textContent = deviceSelected ? 'See Setup for connection details.' : '';
        $('#wiimConnectionHelp').textContent = deviceSelected ? error.message : '';
        $('#playingAudio').textContent = '';
        $('#playingArt').hidden = true;
        $('#now').textContent = error.message;
    }
}
let playingAlbumKey='',playingAlbumRequest=0;const playingAlbums=new Map();
async function expandPlayingAlbum(){
    const id=currentTrackId;const fallback=lastQueue?.entry.albumId;
    const key=/^[1-9][0-9]*$/.test(id)?'track:'+id:fallback?'album:'+fallback:'';
    if(!key){$('#playingTracks').textContent='No current album reported by WiiM.';return}
    if(playingAlbumKey===key)return;playingAlbumKey=key;const token=++playingAlbumRequest;$('#playingTracks').textContent='Loading current album…';
    try{let albumId=fallback;if(key.startsWith('track:')){const t=await api('/api/track/'+id);albumId=t.album_id}if(!albumId)throw Error('Current track has no album metadata');if(!playingAlbums.has(String(albumId)))playingAlbums.set(String(albumId),await api('/api/album/'+albumId));if(token!==playingAlbumRequest||playingAlbumKey!==key)return;const data=playingAlbums.get(String(albumId));$('#playingTracks').innerHTML=`<h3>${esc(data.album.name)}</h3>${trackRows(data)}`;bindTrackRows($('#playingTracks'),data)}catch(e){if(token===playingAlbumRequest){playingAlbumKey='';$('#playingTracks').textContent='Unable to load current album: '+e.message}}
}
let seeking = false, seekPending = false, positionSample = null;

function playbackTime(seconds) {
    seconds = Math.max(0, Math.floor(Number(seconds) || 0));
    return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}

function renderPosition() {
    if (seeking || seekPending) return;
    const seek = $('#seek');
    const sample = positionSample;
    const drift = sample?.playing ? Math.max(0, performance.now() - sample.at) / 1000 : 0;
    const position = sample ? Math.floor(Math.min(sample.duration, sample.position + drift)) : 0;
    seek.disabled = !sample;
    seek.max = sample ? Math.floor(sample.duration) : 0;
    seek.value = position;
    $('#elapsed').textContent = playbackTime(position);
    $('#duration').textContent = sample ? playbackTime(sample.duration) : '—';
}

function updateSeek(metadata) {
    const duration = Number(metadata.durationMs) / 1000;
    const position = Number(metadata.positionMs) / 1000;
    const valid = Number.isFinite(duration) && duration > 0 && metadata.positionMs != null
        && Number.isFinite(position) && position >= 0;
    positionSample = valid ? {
        duration, position, at: performance.now(), playing: metadata.playbackStatus === 'play',
    } : null;
    renderPosition();
}

async function seekPlayback() {
    if ($('#seek').disabled || seekPending || controlBusy) {
        seeking = false;
        renderPosition();
        return;
    }
    const value = Math.round(Number($('#seek').value));
    seeking = false;
    seekPending = true;
    try {
        await controlPlayer('seek', value);
    } finally {
        seekPending = false;
        renderPosition();
    }
}
function updateVolume(value){const volume=Math.max(0,Math.min(100,Number(value)));$('#volume').value=volume;$('#volumeValue').textContent=volume;$('#volume').style.setProperty('--volume-fill',volume+'%')}
function updateTransport(m){updateSeek(m);const state=m.playbackStatus;$('#togglePlayback').textContent=state==='play'?'⏸':state==='pause'||state==='stop'?'▶':'⏯';$('#togglePlayback').setAttribute('aria-label',state==='play'?'Pause':state==='pause'||state==='stop'?'Play':'Play or pause');const volume=Number(m.volume);const valid=m.volume!==null&&m.volume!==undefined&&Number.isFinite(volume)&&volume>=0&&volume<=100;$('#volume').disabled=!valid;if(valid&&document.activeElement!==$('#volume'))updateVolume(volume)}
async function controlPlayer(action, value) {
    if (controlBusy) return;
    controlBusy = true;
    setTransportReady(transportReady);
    try {
        await api('/api/control', {method:'POST', body:JSON.stringify({action,value})});
        await now(true);
    } catch (error) {
        $('#playingState').textContent = 'Control unavailable';
        $('#now').textContent = error.message;
    } finally {
        controlBusy = false;
        setTransportReady(transportReady);
    }
}
function playbackKeydown(event){
    if(event.defaultPrevented||event.repeat||event.isComposing||event.ctrlKey||event.metaKey||event.altKey)return;
    const target=event.target;
    if(target?.isContentEditable||target?.closest?.('input,select,textarea,button,a,summary,[role="button"],[contenteditable],dialog'))return;
    if($('#playDialog').open||$('#recentDialog').open||$('#detail').open||submitting||$('#togglePlayback').disabled)return;
    const actions={' ':'toggle',ArrowLeft:'previous',ArrowRight:'next',MediaPlayPause:'toggle',MediaTrackPrevious:'previous',MediaTrackNext:'next'};
    if(actions[event.key]){event.preventDefault();controlPlayer(actions[event.key]);return}
    if(event.key==='ArrowUp'||event.key==='ArrowDown'){
        if($('#volume').disabled)return;
        event.preventDefault();const value=Math.max(0,Math.min(100,Number($('#volume').value)+(event.key==='ArrowUp'?5:-5)));
        updateVolume(value);controlPlayer('volume',value);
    }
}
let discoveryBusy = false;
let deviceSelected = false;
let deviceHost = '';
let wiimConnectionState = '';
let serverStopped = false;

function discoveryMessage(text, error = false) {
    const status = $('#discoveryStatus');
    status.textContent = text;
    status.className = 'feedback muted' + (error ? ' error' : '');
}

function setConnectionBadge(card, label, badge, state, text) {
    $(card).setAttribute('data-state', state);
    $(badge).setAttribute('data-state', state);
    for (const selector of [label, badge]) {
        if ($(selector).textContent !== text) $(selector).textContent = text;
    }
}

function updateDiscoveryButton() {
    const button = $('#discoverWiim');
    button.disabled = discoveryBusy || serverStopped;
    button.textContent = discoveryBusy ? 'Discovering…'
        : wiimConnectionState === 'ready' ? 'Find another WiiM'
        : deviceSelected ? 'Find WiiM again' : 'Discover WiiM';
}

function showWiimConnection(state, label) {
    wiimConnectionState = state;
    setConnectionBadge('#wiimConnectionCard', '#wiimConnection', '#wiimSetupState', state, label);
    updateDiscoveryButton();
}

function showDevice(host, name) {
    const selectedHost = host || '';
    const changed = selectedHost !== deviceHost;
    deviceHost = selectedHost;
    deviceSelected = Boolean(selectedHost);
    document.body.dataset.device = deviceSelected ? 'selected' : 'unselected';
    $('#wiimLabel').textContent = deviceSelected ? name || 'WiiM' : 'WiiM';
    $('#wiimLabel').title = selectedHost;
    $('#wiimSetupStatus').textContent = deviceSelected
        ? `${name || 'WiiM'} · ${selectedHost}`
        : 'Connect your Mac and WiiM to the same network.';
    if (changed) {
        $('#wiimConnectionHelp').textContent = '';
        ++deviceRevision;
        setTransportReady(false);
        updateSeek({});
        $('#volume').disabled = true;
    }
    if (changed || !deviceSelected) {
        showWiimConnection(deviceSelected ? 'checking' : '', deviceSelected ? 'Connecting…' : 'Not selected');
        if (deviceSelected) {
            $('#playingTitle').textContent = 'Connecting to WiiM…';
            $('#playingArtist').textContent = '';
        }
    }
}

async function connectedDevice(device) {
    showDevice(device.host, device.name);
    $('#devicePicker').hidden = true;
    discoveryMessage('');
    currentTrackId = '';
    lastQueue = null;
    playingAlbumKey = '';
    ++playingAlbumRequest;
    $('#playingTracks').textContent = '';
    await now(true);
}

async function discoverWiim() {
    if (discoveryBusy) return;
    discoveryBusy = true;
    updateDiscoveryButton();
    $('#devicePicker').hidden = true;
    discoveryMessage('Searching your local network…');
    try {
        const result = await api('/api/wiim/discover', {method:'POST'});
        if (result.selected) {
            await connectedDevice(result.selected);
        } else if (!result.devices.length) {
            discoveryMessage('No WiiM found. Check that it is on the same network, or enter its address below.', true);
        } else {
            $('#wiimDevices').innerHTML = result.devices.map(device =>
                `<option value="${esc(device.id)}">${esc(device.name)} · ${esc(device.host)}</option>`).join('');
            $('#devicePicker').hidden = false;
            discoveryMessage('Choose which WiiM to use.');
            $('#wiimDevices').focus();
        }
    } catch (error) {
        discoveryMessage(error.message, true);
    } finally {
        discoveryBusy = false;
        updateDiscoveryButton();
    }
}

async function connectWiim() {
    const button = $('#connectWiim');
    button.disabled = true;
    try {
        const {selected} = await api('/api/wiim/select', {
            method:'POST', body:JSON.stringify({id:$('#wiimDevices').value}),
        });
        await connectedDevice(selected);
    } catch (error) {
        discoveryMessage(error.message, true);
    } finally {
        button.disabled = false;
    }
}

let searchRequest = 0;
$('#searchForm').onsubmit=async event => {
    event.preventDefault();
    const query = $('#query').value.trim();
    const types = [...$('#searchTypes').querySelectorAll('[aria-pressed="true"]')]
        .map(button => button.dataset.searchType);
    if (!query) {
        msg('Enter an album, track, or artist name.', true);
        return;
    }
    if (!types.length) {
        msg('Select at least one search category.', true);
        return;
    }
    $('#currentPlayer').open = false;
    closeAlbum();
    active = null;
    ++albumRequest;
    const token = ++searchRequest;
    const button = $('#searchButton');
    button.textContent = 'Searching…';
    msg('Searching TIDAL…');
    try {
        const params = new URLSearchParams({q:query, types:types.join(',')});
        const data = await api('/api/search?' + params);
        if (token !== searchRequest) return;
        results = {artist: data.artistAlbums || [], album: data.albums || [], track: data.tracks || []};
        resultQuery = query;
        searched = true;
        $('#searchHero').className = 'hero compact';
        drawRecentShelf();
        $('#resultsHeading').textContent = `Results for “${query}”`;
        $('#searchResults').hidden = false;
        $('#hiResOnly').checked = false;
        populateAlbumFilters(true);
        sectionState.clear();
        draw();
        msg('');
    } catch (error) {
        if (token === searchRequest) msg(error.message, true);
    } finally {
        if (token === searchRequest) button.textContent = 'Search';
    }
};
$('#searchTypes').querySelectorAll('[data-search-type]').forEach(button => {
    button.onclick = () => button.setAttribute('aria-pressed', String(button.getAttribute('aria-pressed') !== 'true'));
});
$('#artistFilter').onchange = () => { populateAlbumFilters(); draw(); };
$('#albumFilter').onchange = draw;
$('#hiResOnly').onchange = () => { populateAlbumFilters(); draw(); };
$('#resetFilters').onclick = () => {
    $('#hiResOnly').checked = false;
    populateAlbumFilters(true);
    draw();
};
$('#expandResults').onclick = () => { setSectionsOpen(true); $('#groupActions').open = false; };
$('#collapseResults').onclick = () => { setSectionsOpen(false); $('#groupActions').open = false; };
$('#currentPlayer').ontoggle = () => { if ($('#currentPlayer').open) expandPlayingAlbum(); };
$('#previousTrack').onclick = () => controlPlayer('previous');
$('#togglePlayback').onclick = () => controlPlayer('toggle');
$('#nextTrack').onclick = () => controlPlayer('next');
$('#seek').oninput = () => { seeking = true; $('#elapsed').textContent = playbackTime($('#seek').value); };
$('#seek').onchange = seekPlayback;
$('#seek').onblur = () => { seeking = false; renderPosition(); };
$('#volume').oninput = () => updateVolume($('#volume').value);
$('#volume').onchange = () => controlPlayer('volume', Number($('#volume').value));
$('#cancelPlay').onclick = cancelPlayback;
$('#playDialog').oncancel = event => { event.preventDefault(); cancelPlayback(); };
$('#recents').onclick = showRecents;
$('#allRecents').onclick = showRecents;
$('#closeRecents').onclick = () => $('#recentDialog').close();
$('#refresh').onclick=now;
$('#discoverWiim').onclick = discoverWiim;
$('#connectWiim').onclick = connectWiim;
$('#detail').onclose = () => { if (!$('#detail').open) $('#detail').hidden = true; };
document.addEventListener('keydown', playbackKeydown);
document.addEventListener('error', event => {
    if (event.target instanceof HTMLImageElement) event.target.hidden = true;
}, true);

function showSetup(show, focus = false) {
    $('#setup').hidden = !show;
    $('#openSetup').setAttribute('aria-expanded', String(show));
    if (focus) (show ? $('#setupHeading') : $('#openSetup')).focus();
}

function showHealth(health) {
    showDevice(health.wiim, health.wiimName);
    const tidalStatus = health.restoring ? 'Checking…' : health.tidal ? 'Connected' : 'Sign in required';
    setConnectionBadge('#tidalConnectionCard', '#connection', '#tidalSetupState',
        health.tidal ? 'ready' : '', tidalStatus);
    $('#tidalSetupStatus').textContent = health.tidal ? 'TIDAL is connected.' : 'Sign in with your TIDAL account.';
    $('#startLogin').disabled = Boolean(health.restoring);
    $('#startLogin').textContent = health.tidal ? 'Reconnect TIDAL' : 'Connect TIDAL';
    if (!deviceSelected) $('#playingTitle').textContent = 'No WiiM selected';
}

$('#openSetup').onclick = () => showSetup($('#setup').hidden, true);
$('#closeSetup').onclick = () => showSetup(false, true);
$('#playerSetup').onclick = () => showSetup(true, true);
$('#exploreNav').onclick = event => {
    event.preventDefault();
    showSetup(false);
    $('#query').focus();
};
$('#startLogin').onclick = async () => {
    const button = $('#startLogin');
    button.disabled = true;
    try {
        const {url} = await api('/api/auth/start', {method:'POST'});
        $('#loginLink').href = url;
        $('#loginInstructions').hidden = false;
        $('#loginLink').focus();
    } catch (error) {
        $('#tidalSetupStatus').textContent = error.message;
    } finally {
        button.disabled = false;
    }
};
$('#loginForm').onsubmit = async event => {
    event.preventDefault();
    const input = $('#redirectUrl');
    const button = event.currentTarget.querySelector('button');
    button.disabled = true;
    $('#tidalSetupStatus').textContent = 'Connecting to TIDAL…';
    try {
        await api('/api/auth/finish', {method:'POST', body:JSON.stringify({redirect:input.value.trim()})});
        input.value = '';
        $('#loginInstructions').hidden = true;
        showHealth(await api('/api/health'));
    } catch (error) {
        $('#tidalSetupStatus').textContent = error.message;
    } finally {
        button.disabled = false;
    }
};
$('#manualDevice').onsubmit = async event => {
    event.preventDefault();
    const button = event.currentTarget.querySelector('button');
    button.disabled = true;
    try {
        const {selected} = await api('/api/wiim/manual', {method:'POST', body:JSON.stringify({
            host:$('#manualHost').value.trim(), port:Number($('#manualPort').value)})});
        $('#manualStatus').textContent = 'Address saved.';
        await connectedDevice(selected);
    } catch (error) {
        $('#manualStatus').textContent = error.message;
    } finally {
        button.disabled = false;
    }
};
$('#stopServer').onclick = async () => {
    try {
        await api('/api/shutdown', {method:'POST'});
        serverStopped = true;
        setConnectionBadge('#tidalConnectionCard', '#connection', '#tidalSetupState', '', 'Server stopped');
        showWiimConnection('', 'Server stopped');
        setTransportReady(false);
        updateSeek({});
        $('#seek').disabled = true;
        $('#volume').disabled = true;
        $('#refresh').disabled = true;
        $('#playingTitle').textContent = 'Local server stopped';
        $('#stopServer').disabled = true;
        msg('Server stopped. Open WiiM TIDAL again to reconnect.');
        showSetup(false);
    } catch (error) {
        msg(error.message, true);
    }
};
function refreshVisiblePlayer() {
    if (!document.hidden && deviceSelected && !serverStopped) now();
}
// Paint from the last device sample so elapsed seconds change between network polls.
setInterval(() => { if (!document.hidden) renderPosition(); }, 250);
setInterval(refreshVisiblePlayer, 5000);
document.addEventListener('visibilitychange', refreshVisiblePlayer);
window.addEventListener('online', refreshVisiblePlayer);
let startupDeviceRevision = -1;
async function loadSetupStatus() {
    try {
        const health = await api('/api/health');
        showHealth(health);
        if (health.wiim && startupDeviceRevision !== deviceRevision) {
            startupDeviceRevision = deviceRevision;
            now();
        }
        if (health.restoring) {
            setTimeout(loadSetupStatus, 750);
            return;
        }
        const needsSetup = !health.tidal || !health.wiim;
        if (needsSetup) $('#searchHero').className = 'hero compact';
        showSetup(needsSetup || new URLSearchParams(location.search).has('setup'));
    } catch (error) {
        msg(error.message, true);
    }
}
drawRecentShelf();
loadSetupStatus();
