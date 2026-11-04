import base64
h=open('index.html').read()
css=open('style.css').read().replace('url(plane.jpg)','url(data:image/jpeg;base64,'+base64.b64encode(open('plane.jpg','rb').read()).decode()+')')
h=h.replace('<link rel="stylesheet" href="style.css">','<style>'+css+'</style>')
h=h.replace('<script src="config.js"></script>','<script>'+open('config.js').read()+'</script>').replace('<script src="app.js"></script>','<script>'+open('app.js').read().replace('</script>','<\\/script>')+'</script>')
open('BENI-System.html','w').write(h)
