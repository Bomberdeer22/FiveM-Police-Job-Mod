const fs=require('fs'); const path=require('path');
const src = fs.readFileSync(path.join(__dirname,'house.test.js'),'utf8');
// extract the harness by evaluating the file up to the assertion marker is hard;
// instead just re-implement luaCallGlobal via the same harness file? Simpler: use
// the test file itself with a debug line.
