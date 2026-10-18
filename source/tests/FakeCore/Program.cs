using System.IO.Pipes;
using System.Text;
var trace=Environment.GetEnvironmentVariable("LINKDESK_TEST_TRACE")!;
File.AppendAllText(trace,Environment.ProcessId+"\n");
using var pipe=new NamedPipeServerStream("deskflow-core",PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous);
await pipe.WaitForConnectionAsync();
using var reader=new StreamReader(pipe,Encoding.UTF8,false,4096,true);
using var writer=new StreamWriter(pipe,new UTF8Encoding(false),4096,true){AutoFlush=true};
using var writeLock=new SemaphoreSlim(1,1);
async Task Send(string message){await writeLock.WaitAsync();try{await writer.WriteLineAsync(message);}finally{writeLock.Release();}}
_ = Task.Run(async ()=>{
 bool failing=false;
 while(true){
  bool active=File.Exists(trace+".linkfail");
  if(active)Console.WriteLine("[fixture] WARNING: failed to connect to server: Timed out");
  else if(failing){Console.WriteLine("[fixture] INFO: connected to secure socket");await Send("connectionState=Connected");}
  failing=active;await Task.Delay(100);
 }
});
while(await reader.ReadLineAsync() is {} line){
 if(File.Exists(trace+".crash"))return 23;
 if(line.StartsWith("hello="))await Send(File.Exists(trace+".linkfail")?"connectionState=Disconnected":"connectionState=Connected");
 if(File.Exists(trace+".hold"))continue;
 if(line.StartsWith("ping=")){File.WriteAllText(trace+".probing","");if(File.Exists(trace+".slowping"))await Task.Delay(400);await Send("pong="+line[5..]);}
 if(line=="stop"){File.WriteAllText(trace+".stopping","");if(File.Exists(trace+".slowstop"))await Task.Delay(500);return 0;}
}
return 0;
