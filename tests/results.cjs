const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('src/wiim_tidal/static/app.js', 'utf8');
const elements = new Map();
const requests = [];
const context = vm.createContext({
    Intl, Map, String, Number, URLSearchParams, console,
    document: {querySelector(selector) {
        if (!elements.has(selector)) elements.set(selector, {
            addEventListener(){}, value:'', innerHTML:'', querySelectorAll:()=>[], close(){this.open=false},
        });
        return elements.get(selector);
    }},
    fetch: async path => {
        requests.push(path);
        return {ok:true,json:async()=>path.startsWith('/api/search?') ? {albums:[],artistAlbums:[],tracks:[]}
            : {bits:24,hz:192000}};
    },
    IntersectionObserver: class {
        constructor(callback){this.callback=callback}
        observe(){} unobserve(){} disconnect(){}
    },
});
const run = code => vm.runInContext(code, context);
run(source.split("$('#searchForm').onsubmit=")[0]);
run(`
resultQuery = '  BECK  ';
results = {
    artist: [
        {id:1, releaseDate:'2002-09-24', year:2002, quality:'LOSSLESS', artist:'Beck', name:'Sea Change'},
        {id:2, releaseDate:'2002-01-01', year:2002, quality:'LOSSLESS', artist:'Beck', name:'Earlier release'},
        {id:3, quality:'Hi-Res Lossless', artist:'Beck', name:'Guero'},
        {id:4, quality:'LOSSLESS', artist:'Alan Beck', name:'Another album'},
        {id:5, quality:'LOSSLESS', artist:'Jeff Beck', name:'Blow by Blow'},
    ],
    album: [{id:6, quality:'LOSSLESS', artist:'A different artist', name:'Beck Sessions'}],
    track: [{id:7, album_id:6, title:'Beck Tribute', album:'Beck Sessions', artist:'A different artist', quality:'HIGH'}],
};
draw();`);
const html = elements.get('#results').innerHTML;
assert.deepEqual([...html.matchAll(/class="result-section match-section" data-section="([^"]+)"/g)].map(m=>m[1]),
    ['artist','album','track']);
assert.ok(!html.includes('Exact matches'), 'exact artists are promoted within quality');
assert.deepEqual([...html.matchAll(/data-id="(\d+)"/g)].map(m=>+m[1]), [3,2,1,4,5,6]);
assert.match(html, /data-search-track="7"/);
assert.match(html, /data-open-album="6"/);
assert.equal(requests.length, 0, 'rendering should not fetch resolutions');

run("$('#artistFilter').value='Beck';populateAlbumFilters();draw()");
assert.match(elements.get('#albumFilter').innerHTML,/Sea Change/);
assert.ok(!elements.get('#results').innerHTML.includes('Blow by Blow'));
run("$('#artistFilter').value='';$('#hiResOnly').checked=true;draw()");
assert.deepEqual([...elements.get('#results').innerHTML.matchAll(/data-id="(\d+)"/g)].map(m=>+m[1]), [3]);
run("$('#hiResOnly').checked=false;draw()");

const sections = [
    {dataset:{section:'artist'}, parentElement:{childElementCount:2}},
    {dataset:{section:'artist-quality-0'}, parentElement:{childElementCount:1}},
];
elements.get('#results').querySelectorAll = selector => selector === 'details[data-section]' ? sections : [];
run('draw()');
assert.deepEqual(sections.map(section=>section.open), [false,true], 'only a section with no siblings opens by default');
sections[1].open = false;
sections[1].ontoggle();
run('draw()');
assert.equal(sections[1].open, false, 'a manual collapse survives a redraw');
run('setSectionsOpen(false)');
assert.ok(sections.every(section=>!section.open));
run('setSectionsOpen(true)');
assert.ok(sections.every(section=>section.open));

(async () => {
    await run('Promise.all([fetchResolution(2), fetchResolution("2")])');
    assert.equal(requests.length, 1, 'resolution requests should share cached work');
    await run('fetchResolution(2)');
    assert.equal(requests.length, 1);
    const label = {textContent:''};
    context.visibleCard = {dataset:{id:'4'}, isConnected:true, querySelector:()=>label};
    run('resolutionObserver.callback([{isIntersecting:true,target:visibleCard}])');
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(requests.length, 2);
    assert.match(label.textContent,/24-bit \/ 192.0 kHz/);

    run(source.slice(source.indexOf("$('#searchForm').onsubmit="),source.indexOf("$('#refresh').onclick=now;")));
    run("$('#query').value='Beck';$('#currentPlayer').open=true;$('#detail').hidden=false;$('#detail').open=true");
    elements.get('#searchTypes').querySelectorAll = () => [
        {dataset:{searchType:'track'}}, {dataset:{searchType:'artist'}},
    ];
    await elements.get('#searchForm').onsubmit({preventDefault(){}});
    const query = new URLSearchParams(requests.at(-1).split('?')[1]);
    assert.equal(query.get('q'), 'Beck');
    assert.equal(query.get('types'), 'track,artist');
    assert.equal(elements.get('#currentPlayer').open, false);
    assert.equal(elements.get('#detail').hidden, true);
    assert.equal(run('sectionState.size'), 0, 'a new search resets expanded sections');
    console.log('PASS: search categories, nested collapsed sections, artist ranking, chronology, and lazy resolution');
})().catch(error=>{console.error(error);process.exitCode=1});
