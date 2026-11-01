// Run with NODE_PATH pointing to a runtime containing playwright and sharp.
const {chromium} = require('playwright');
const sharp = require('sharp');
const fs = require('node:fs/promises');
const path = require('node:path');
(async () => {
  const root = path.resolve(__dirname, '../..');
  const resources = path.join(root, 'app/Resources');
  const iconset = path.join(root, 'app/build/Ledge.iconset');
  await fs.mkdir(resources, {recursive:true}); await fs.mkdir(iconset, {recursive:true});
  const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless:true});
  const page = await browser.newPage({deviceScaleFactor:1});
  const tiles = [];
  try {
    for (const size of [16,32,64,128,256,512,1024]) {
      const svg = await fs.readFile(path.join(root, 'design/app-icon', size <= 32 ? 'ledge-icon-small.svg' : 'ledge-icon.svg'), 'utf8');
      await page.setViewportSize({width:size,height:size});
      await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style>${svg}`);
      const png = await page.screenshot({omitBackground:true});
      for (const points of [16,32,128,256,512]) for (const scale of [1,2]) if (points*scale === size) await fs.writeFile(path.join(iconset, `icon_${points}x${points}${scale===2?'@2x':''}.png`), png);
      tiles.push(await sharp(png).resize(128,128,{kernel:'nearest'}).png().toBuffer());
    }
    for (const scale of [1,2]) {
      const size = 16*scale;
      const svg = await fs.readFile(path.join(root, 'design/app-icon/ledge-menubar-template.svg'),'utf8');
      await page.setViewportSize({width:size,height:size});
      await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style>${svg}`);
      const png = await page.screenshot({omitBackground:true});
      await fs.writeFile(path.join(resources, `MenuBarTemplate${scale===2?'@2x':''}.png`), png);
      tiles.push(await sharp(png).resize(128,128,{kernel:'nearest'}).png().toBuffer());
    }
    await sharp({create:{width:128*tiles.length,height:128,channels:4,background:'#999999'}}).composite(tiles.map((input,i)=>({input,left:i*128,top:0}))).png().toFile(path.join(root,'app/build/ledge-icons-review.png'));
    console.log('Rendered SVG filters in Chromium: 7 pixel sizes and 2 menu representations. Review order: 16,32,64,128,256,512,1024,menu16,menu32.');
  } finally { await browser.close(); }
})().catch(error=>{ console.error(error); process.exitCode=1; });
