import os, pty, sys, fcntl, termios, struct, select, time
# usage: drive.py <launcher> <env-file>  -- runs launcher start under a 40x120 pty
launcher=sys.argv[1]; envfile=sys.argv[2]; args=sys.argv[3:]
env={}
for l in open(envfile):
    l=l.rstrip('\n')
    if l: k,v=l.split('=',1); env[k]=v
pid,fd=pty.fork()
if pid==0:
    fcntl.ioctl(0,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
    os.execve(launcher,[launcher]+args,env)
fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
out=b''
while True:
    r,_,_=select.select([fd],[],[],60)
    if not r: break
    try: d=os.read(fd,4096)
    except OSError: break
    if not d: break
    out+=d
_,st=os.waitpid(pid,0)
sys.stdout.write(out.decode(errors='replace'))
print(f"[exit status {os.waitstatus_to_exitcode(st)}]")
