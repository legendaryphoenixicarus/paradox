const fs = require("fs");

let allLines = fs
  .readFileSync("../data/paradoxSnapshot.txt")
  .toString()
  .split("\n");

fs.writeFileSync("../data/paradoxSnapshot.txt", "", function () {
  console.log("file is empty");
});
allLines.forEach(function (line) {
  const newLine = line + ",";
  console.log(newLine);
  fs.appendFileSync("./input.txt", newLine.toString() + "\n");
});

// each line would have "candy" appended
allLines = fs
  .readFileSync("../data/paradoxSnapshot.txt")
  .toString()
  .split("\n");
