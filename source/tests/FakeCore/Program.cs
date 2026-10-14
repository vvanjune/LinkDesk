using System.IO.Pipes;
using System.Text;
var trace=Environment.GetEnvironmentVariable("LINKDESK_TEST_TRACE")!;
File.AppendAllText(trace,Environment.ProcessId+"\n");
using var pipe=new NamedPipeServerStream("deskflow-core",PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous);
await pipe.WaitForConnectionAsync();
using var reader=new StreamReader(pipe,Encoding.UTF8,false,4096,true);
using var writer=new StreamWriter(pipe,new UTF8Encoding(false),4096,true){AutoFlush=true};
while(await reader.ReadLineAsync() is {} line){
 if(File.Exists(trace+".crash"))return 23;
 if(line.StartsWith("hello="))await writer.WriteLineAsync("connectionState=Connected");
 if(File.Exists(trace+".hold"))continue;
 if(line.StartsWith("ping="))await writer.WriteLineAsync("pong="+line[5..]);
 if(line=="stop")return 0;
}
return 0;
