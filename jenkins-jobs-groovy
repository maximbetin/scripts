// Gets the jobs that ran in a specific timeframe.

jenkins = Jenkins.instance

Calendar after = Calendar.getInstance()
Calendar before = Calendar.getInstance()
//set(int year, int month, int date, int hourOfDay, int minute,int second)

// Months start from 0 to 11
after.set(2020,9,29,6,21,0)
before.set(2020,9,29,10,42,0)

println "Jobs ran between " + after.getTime() + " - " + before.getTime()

// Use regex to filter by job name
def regex = ~/(.*)(job-name)(.*)/

for (job in jenkins.getAllItems(Job.class)) {
  for(Run run in job.getBuilds()){
    if (run.getTimestamp()?.before(before) && run.getTimestamp()?.after(after)) {
      if(job.name ==~ regex) {
        println "" + run.getResult() + " " + job.name + " " + run.getTime()
      }  
    }
  }
}
